#!/usr/bin/env python3
"""C4 모델 HTML 무결성 검증.

검사 항목:
  1. c4Graph([...]) 의 from/to/label 이 같은 파일 안의 id="..." 와 전부 대응하는가
     (누락 시 c4core.js 가 엣지를 '조용히' 건너뛰므로 육안으로 잡기 어려움 — 최다 발생 버그)
  2. 로컬 href / data-href 링크 대상 파일이 실제로 존재하는가
  3. 외부 URL 이 Google Fonts 외에 없는가 (오프라인 열람 보장)
  4. views/c4.js 의 VIEWS[] 항목과 views/c4-*.html 파일 목록이 1:1 인가

사용법:
  python3 verify_c4.py                # 스크립트가 있는 폴더를 검사
  python3 verify_c4.py <폴더> [<폴더>...]  # 지정 폴더들 검사 (다른 repo 의 c4model 도 가능)

종료 코드: 오류 있으면 1, 없으면 0.
"""
import re, sys, os, glob

errors = []
warnings = []


def check_file(path, folder):
    with open(path, encoding="utf-8") as f:
        src = f.read()
    rel = os.path.relpath(path, folder)
    ids = set(re.findall(r'id="([^"]+)"', src))

    m = re.search(r'c4Graph\(\[(.*?)\]\)', src, re.S)
    if m:
        body = m.group(1)
        for key in ("from", "to", "label"):
            for val in re.findall(rf"{key}\s*:\s*'([^']+)'", body):
                if val not in ids:
                    errors.append(f"{rel}: c4Graph {key}:'{val}' 에 대응하는 id 없음")

    for attr, target in re.findall(r'(href|data-href)="([^"]+)"', src):
        if target.startswith(("http://", "https://", "#", "mailto:")):
            continue
        t = target.split("#")[0]
        if not t:
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(path), t))
        if not os.path.exists(resolved):
            errors.append(f"{rel}: 깨진 링크 {attr}={target}")

    for url in re.findall(r'https?://([^/"\s]+)', src):
        if url not in ("fonts.googleapis.com", "fonts.gstatic.com", "www.w3.org"):
            warnings.append(f"{rel}: 외부 URL {url}")


def check_views_registry(folder):
    js = os.path.join(folder, "views", "c4.js")
    if not os.path.exists(js):
        return
    with open(js, encoding="utf-8") as f:
        src = f.read()
    declared = set(re.findall(r"file:\s*'([^']+)'", src))
    actual = {os.path.basename(p) for p in glob.glob(os.path.join(folder, "views", "c4-*.html"))}
    for d in sorted(declared - actual):
        errors.append(f"{folder}/views: VIEWS[]에 있으나 파일 없음: {d}")
    for a in sorted(actual - declared):
        warnings.append(f"{folder}/views: 파일은 있으나 VIEWS[] 미등록: {a}")


def main():
    folders = [os.path.abspath(a) for a in sys.argv[1:]] or [os.path.dirname(os.path.abspath(__file__))]
    total = 0
    for folder in folders:
        files = sorted(glob.glob(os.path.join(folder, "*.html")) + glob.glob(os.path.join(folder, "views", "*.html")))
        total += len(files)
        for p in files:
            check_file(p, folder)
        check_views_registry(folder)
        print(f"[{os.path.basename(folder)}] HTML {len(files)}개 검사")

    print(f"\n총 {total}개 파일 · 오류 {len(errors)} · 경고 {len(warnings)}")
    for e in errors:
        print("ERROR:", e)
    for w in warnings:
        print("WARN :", w)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
