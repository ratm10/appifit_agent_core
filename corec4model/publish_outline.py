#!/usr/bin/env python3
"""C4 모델을 Outline 위키에 게시한다 (레벨별 전체페이지 스크린샷 임베드 + 원본 HTML zip 첨부).

각 C4 HTML 페이지를 headless Chrome(DevTools Protocol)로 전체 높이 PNG 렌더 ->
Outline attachments 로 업로드 -> 해당 repo 의 As-Is 문서 하위에 "C4 아키텍처 모델"
문서를 생성/갱신한다. 원본 c4model 폴더 전체는 zip 으로 함께 첨부(인터랙티브 열람용).

Outline 은 Markdown+이미지 위키라 인터랙티브 HTML 을 그대로 렌더하지 못하므로
"스크린샷 스냅샷 + 원본 zip" 조합으로 담는다.

스크린샷은 CDP `Page.captureScreenshot(captureBeyondViewport)` 로 페이지 전체 높이를
한 번에 캡처한다(창 높이 고정 방식은 position:fixed 요소가 창 하단에 박혀 빈 공간이
생기므로 사용하지 않는다). Chrome 인스턴스는 1개만 띄워 전 페이지를 처리한다.

설정은 repo 루트 .env 에서 읽는다 (모두 gitignore 대상):
  OUTLINE_KEY            Outline API 토큰
  OUTLINE_URL            기본 https://waldlust.getoutline.com
  OUTLINE_COLLECTION_ID  게시 컬렉션
  OUTLINE_ASIS_DOC_ID    이 repo 의 As-Is 문서 (C4 문서의 부모)

사용법:
  python3 <c4폴더>/publish_outline.py            # 게시(생성 또는 갱신)
  python3 <c4폴더>/publish_outline.py --dry-run  # 스크린샷/조립만, 업로드·게시 skip

멱등성: 최초 생성 시 문서 id 를 <c4폴더>/.outline_c4_doc_id 에 저장하고,
이후 실행은 그 문서를 갱신한다(.outline_c4_doc_id 는 gitignore).
"""
import os
import re
import sys
import time
import json
import glob
import uuid
import base64
import struct
import socket
import shutil
import hashlib
import zipfile
import subprocess
import html as htmllib
import urllib.parse
import urllib.request
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDER_NAME = os.path.basename(HERE)          # e.g. agentc4model
REPO_ROOT = os.path.dirname(HERE)
DRY = "--dry-run" in sys.argv
DOC_TITLE = "C4 아키텍처 모델"
SIDECAR = os.path.join(HERE, ".outline_c4_doc_id")
WIDTH = 1440

CHROME = os.environ.get("CHROME_BIN") or \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if not os.path.exists(CHROME):
    CHROME = (shutil.which("google-chrome") or shutil.which("chromium")
              or shutil.which("chrome") or CHROME)


def die(msg):
    print("[publish] 오류:", msg, file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- .env
def load_env():
    env = {}
    p = os.path.join(REPO_ROOT, ".env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = load_env()
KEY = ENV.get("OUTLINE_KEY")
BASE = (ENV.get("OUTLINE_URL") or "https://waldlust.getoutline.com").rstrip("/")
COLLECTION = ENV.get("OUTLINE_COLLECTION_ID")
PARENT = ENV.get("OUTLINE_ASIS_DOC_ID")


# ================================================================ CDP 스크린샷
class _WS:
    """CDP 용 최소 WebSocket 클라이언트 (stdlib 만 사용)."""

    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + (("?" + u.query) if u.query else "")
        req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.sock.recv(4096)
        self._buf = buf.split(b"\r\n\r\n", 1)[1]

    def _exact(self, n):
        while len(self._buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise IOError("ws closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send(self, obj):
        payload = json.dumps(obj).encode()
        n = len(payload)
        header = bytearray([0x81])
        mask = os.urandom(4)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def recv(self):
        data = b""
        while True:
            b0, b1 = self._exact(2)
            fin = b0 & 0x80
            ln = b1 & 0x7f
            if ln == 126:
                ln = struct.unpack(">H", self._exact(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._exact(8))[0]
            data += self._exact(ln)
            if fin:
                break
        return json.loads(data.decode())

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


class Chrome:
    def __init__(self):
        self.port = self._free_port()
        self.proc = subprocess.Popen(
            [CHROME, "--headless=new", "--disable-gpu", "--no-sandbox",
             "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
             "--force-device-scale-factor=1", "--disable-extensions",
             f"--remote-debugging-port={self.port}", "about:blank"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(150):
            try:
                urllib.request.urlopen(
                    f"http://127.0.0.1:{self.port}/json/version", timeout=0.5).read()
                return
            except Exception:
                time.sleep(0.1)
        die("Chrome DevTools 기동 실패")

    @staticmethod
    def _free_port():
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        p = s.getsockname()[1]
        s.close()
        return p

    def _http(self, path, method="GET"):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}", method=method)
        return json.load(urllib.request.urlopen(req, timeout=10))

    def shot(self, file_url, out_png):
        tab = self._http("/json/new", method="PUT")
        ws = _WS(tab["webSocketDebuggerUrl"])
        mid = [0]

        def cmd(method, params=None):
            mid[0] += 1
            i = mid[0]
            ws.send({"id": i, "method": method, "params": params or {}})
            while True:
                m = ws.recv()
                if m.get("id") == i:
                    if "error" in m:
                        raise RuntimeError(m["error"])
                    return m.get("result", {})
        try:
            cmd("Page.enable")
            cmd("Emulation.setDeviceMetricsOverride",
                {"width": WIDTH, "height": 900, "deviceScaleFactor": 1,
                 "mobile": False})
            cmd("Page.navigate", {"url": file_url})
            # 폰트 로드 완료까지 대기하며 전체 높이 취득 (readyState 재시도 포함)
            height = 0
            for _ in range(60):
                r = cmd("Runtime.evaluate", {
                    "expression": "document.readyState==='complete' ? "
                                  "document.fonts.ready.then(()=>Math.ceil("
                                  "document.documentElement.scrollHeight)) : 0",
                    "awaitPromise": True, "returnByValue": True})
                height = int(r.get("result", {}).get("value") or 0)
                if height > 200:
                    break
                time.sleep(0.15)
            height = max(height, 900)
            shot = cmd("Page.captureScreenshot", {
                "format": "png", "captureBeyondViewport": True,
                "clip": {"x": 0, "y": 0, "width": WIDTH,
                         "height": height, "scale": 1}})
            open(out_png, "wb").write(base64.b64decode(shot["data"]))
        finally:
            ws.close()
            try:
                self._http(f"/json/close/{tab['id']}")
            except Exception:
                pass

    def stop(self):
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


# ---------------------------------------------------------------- Outline API
def api(path, payload):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        die(f"{path} -> HTTP {e.code}: {e.read().decode()[:400]}")


def upload_attachment(local_path, name, content_type):
    size = os.path.getsize(local_path)
    d = api("/api/attachments.create", {
        "name": name, "contentType": content_type,
        "size": size, "preset": "documentAttachment"})["data"]
    form, up, att = d["form"], d["uploadUrl"], d["attachment"]
    boundary = "----outline" + uuid.uuid4().hex
    parts = []
    for k, v in form.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"'
            f'\r\n\r\n{v}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
        f'filename="{name}"\r\nContent-Type: {content_type}\r\n\r\n'.encode())
    parts.append(open(local_path, "rb").read() + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(
        up, data=b"".join(parts),
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST")
    try:
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        die(f"S3 업로드 실패 ({name}): HTTP {e.code} {e.read().decode()[:300]}")
    return att


# ---------------------------------------------------------------- 페이지 수집
def title_of(path):
    src = open(path, encoding="utf-8").read()
    m = re.search(r'<div class="ghdr">.*?<h1>(.*?)</h1>', src, re.S)
    if m:
        t = htmllib.unescape(re.sub(r"<[^>]+>", "", m.group(1))).strip()
        return re.sub(r"^Level\s+\d+\s*[—-]\s*", "", t)
    m = re.search(r"<title>(.*?)</title>", src, re.S)
    return htmllib.unescape(m.group(1)).strip() if m else os.path.basename(path)


def views_order():
    jsp = os.path.join(HERE, "views", "c4.js")
    out = []
    if os.path.exists(jsp):
        src = open(jsp, encoding="utf-8").read()
        for m in re.finditer(r"file:\s*'([^']+)'\s*,\s*label:\s*'([^']+)'", src):
            out.append((m.group(1), m.group(2)))
    return out


def collect_pages():
    pages = []

    def add(path, level, title):
        if os.path.exists(path):
            pages.append({"path": path, "level": level, "title": title})
    add(os.path.join(HERE, "c4core-context.html"), "L1", "System Context")
    add(os.path.join(HERE, "c4core-l2.html"), "L2", "Container")
    for p in sorted(glob.glob(os.path.join(HERE, "c4core-l3-*.html"))):
        add(p, "L3", title_of(p))
    for p in sorted(glob.glob(os.path.join(HERE, "c4core-l4-*.html"))):
        add(p, "L4", title_of(p))
    for fn, label in views_order():
        add(os.path.join(HERE, "views", fn), "VIEW", label)
    return pages


# ---------------------------------------------------------------- zip
def make_zip(dst):
    skip = {"publish_outline.py", ".outline_c4_doc_id", "__pycache__",
            ".DS_Store", "_shots"}
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(HERE):
            dirs[:] = [d for d in dirs if d not in skip]
            for fn in files:
                if fn in skip or fn.endswith(".png"):
                    continue
                full = os.path.join(root, fn)
                arc = os.path.join(FOLDER_NAME, os.path.relpath(full, HERE))
                z.write(full, arc)


def git_info():
    def g(args):
        try:
            return subprocess.check_output(
                ["git"] + args, cwd=REPO_ROOT,
                stderr=subprocess.DEVNULL).decode().strip()
        except Exception:
            return "?"
    return g(["rev-parse", "--abbrev-ref", "HEAD"]), g(["rev-parse", "--short", "HEAD"])


# ---------------------------------------------------------------- main
def main():
    if not DRY and not KEY:
        die(".env 에 OUTLINE_KEY 가 없습니다.")
    if not DRY and (not COLLECTION or not PARENT):
        die(".env 에 OUTLINE_COLLECTION_ID / OUTLINE_ASIS_DOC_ID 가 필요합니다.")

    pages = collect_pages()
    if not pages:
        die(f"{HERE} 에서 c4 HTML 을 찾지 못했습니다.")
    print(f"[publish] {FOLDER_NAME}: {len(pages)}개 페이지")

    shot_dir = os.path.join(HERE, "_shots")
    os.makedirs(shot_dir, exist_ok=True)
    branch, commit = git_info()

    # 1) 스크린샷 (Chrome 1개 재사용)
    chrome = Chrome()
    try:
        for i, pg in enumerate(pages):
            pg["png"] = os.path.join(shot_dir, f"{i:02d}_{pg['level']}.png")
            chrome.shot("file://" + urllib.parse.quote(pg["path"]), pg["png"])
            print(f"  촬영 {pg['level']:4} {pg['title']}")
    finally:
        chrome.stop()

    # 2) zip
    zip_path = os.path.join(shot_dir, f"{FOLDER_NAME}.zip")
    make_zip(zip_path)
    print(f"  zip {os.path.getsize(zip_path)//1024} KB")

    if DRY:
        print(f"[publish] --dry-run: 산출물 {shot_dir} · 업로드 skip.")
        return

    # 3) 업로드
    for pg in pages:
        att = upload_attachment(pg["png"], f"{FOLDER_NAME}_{pg['level']}.png", "image/png")
        pg["img"] = att["url"]
    zip_att = upload_attachment(zip_path, f"{FOLDER_NAME}.zip", "application/zip")

    # 4) 본문 조립
    lines = [
        f"> 📐 이 문서는 `{FOLDER_NAME}/` 정적 HTML C4 모델의 **스크린샷 스냅샷**입니다. "
        f"드릴다운·드래그 등 인터랙션은 하단 **원본 zip**을 받아 `c4core-context.html`을 "
        f"브라우저로 열어 사용하세요. C4 개념·작성 규약: appfit_order_agent `docs/C4_GUIDE.md`.",
        "",
    ]
    grouped = {"L1": [], "L2": [], "L3": [], "L4": [], "VIEW": []}
    for pg in pages:
        grouped[pg["level"]].append(pg)
    head = {"L1": "## L1 — System Context", "L2": "## L2 — Container",
            "L3": "## L3 — Component", "L4": "## L4 — Code",
            "VIEW": "## 별첨 뷰 (Views)"}
    for lvl in ["L1", "L2", "L3", "L4", "VIEW"]:
        if not grouped[lvl]:
            continue
        lines += [head[lvl], ""]
        for pg in grouped[lvl]:
            if lvl in ("L1", "L2"):
                lines.append(f"![{pg['title']}]({pg['img']})")
            else:
                lines += [f"### {pg['title']}", f"![{pg['title']}]({pg['img']})"]
            lines.append("")
    lines += [
        "## 인터랙티브 원본 (다운로드)",
        "",
        f"[{FOLDER_NAME}.zip]({zip_att['url']}) — 압축 해제 후 `c4core-context.html`을 "
        f"브라우저로 열면 L1→L2→L3→L4 드릴다운·별첨 뷰 이동이 동작합니다.",
        "",
        "---",
        f"*생성: `{FOLDER_NAME}/publish_outline.py` · 소스 `{branch}` @ `{commit}` · "
        f"{len(pages)}페이지 · 아키텍처 변경 시 재실행으로 갱신*",
    ]
    text = "\n".join(lines)

    # 5) 문서 생성/갱신
    doc_id = open(SIDECAR).read().strip() if os.path.exists(SIDECAR) else ""
    if doc_id:
        res = api("/api/documents.update",
                  {"id": doc_id, "title": DOC_TITLE, "text": text, "publish": True})
        print("[publish] 갱신:", BASE + res["data"]["url"])
    else:
        res = api("/api/documents.create",
                  {"title": DOC_TITLE, "text": text, "collectionId": COLLECTION,
                   "parentDocumentId": PARENT, "publish": True})
        open(SIDECAR, "w").write(res["data"]["id"])
        print("[publish] 생성:", BASE + res["data"]["url"])

    shutil.rmtree(shot_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
