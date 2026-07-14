# Claude 메모리 공유 셋업

Claude Code 의 프로젝트 메모리는 기본적으로 홈 디렉터리
(`~/.claude/projects/<프로젝트-슬러그>/memory/`)에 저장된다. 이 슬러그는 레포의
절대 경로에서 생성되므로 **머신마다 달라지고**, 메모리는 로컬에만 남아 맥/PC 간
공유가 되지 않는다.

그래서 이 레포는 메모리 실물 파일을 `.claude/memory/` 에 두고 git 으로 추적한다.
각 머신에서는 홈 디렉터리의 메모리 경로를 이 폴더로 **심볼릭 링크**만 걸어주면
된다. 이후 메모리 작성/수정은 곧바로 git 변경분으로 잡히고, 기존 push/pull
워크플로로 양쪽 머신에 공유된다.

심볼릭 링크는 레포 바깥에서 안쪽을 가리키므로 git 에 심링크 자체가 저장되지 않는다.
따라서 크로스플랫폼 문제가 없고, 머신마다 아래 명령을 **최초 1회만** 실행하면 된다.

## 슬러그 확인

`~/.claude/projects/` 아래에서 이 레포에 해당하는 디렉터리를 찾는다. 레포 절대
경로의 `/`(또는 `\`)와 `_` 가 `-` 로 치환된 형태다. 이 레포는 디렉터리명이
`appifit_agent_core` 이므로(패키지명 `appfit_core` 와 다름) 슬러그도
`appifit-agent-core` 로 끝난다.

- Windows 예: `c--Users-Administrator-Documents-GitHub-appifit-agent-core`
- macOS 예: `-Users-<계정>-Documents-GitHub-appifit-agent-core`

이 레포로 Claude 세션을 아직 연 적이 없다면 슬러그 디렉터리 자체가 없을 수 있다.
그때는 `mkdir -p` 로 먼저 만든 뒤 링크한다(아래 명령에 포함돼 있다).

## macOS / Linux

```sh
REPO="$HOME/Documents/GitHub/appifit_agent_core"      # 실제 레포 경로로
SLUG="-Users-$(whoami)-Documents-GitHub-appifit-agent-core"   # 실제 경로에 맞게
MEM="$HOME/.claude/projects/$SLUG/memory"

mkdir -p "$(dirname "$MEM")"
# 기존 로컬 메모리가 있으면 먼저 백업(내용이 레포와 다르면 수동 병합)
[ -e "$MEM" ] && [ ! -L "$MEM" ] && mv "$MEM" "$MEM.bak"

ln -s "$REPO/.claude/memory" "$MEM"
ls -l "$MEM"    # -> .../appifit_agent_core/.claude/memory 로 표시되면 성공
```

## Windows (Git Bash)

개발자 모드 또는 관리자 권한이 필요하다.

```sh
REPO="C:/Users/<계정>/Documents/GitHub/appifit_agent_core"
MEM="C:/Users/<계정>/.claude/projects/<슬러그>/memory"

mkdir -p "$(dirname "$MEM")"
[ -e "$MEM" ] && [ ! -L "$MEM" ] && mv "$MEM" "$MEM.bak"

MSYS=winsymlinks:nativestrict ln -s "$REPO/.claude/memory" "$MEM"
```

## 주의

- 이 레포의 `.gitignore` 는 원래 `.claude/` 를 통째로 무시했다. 메모리만 추적하려고
  `.claude/*` + `!.claude/memory/` 형태로 바꿔 두었다. **이 예외를 지우면 메모리
  공유가 조용히 끊긴다.**
- 양쪽 머신에서 같은 메모리 파일을 고치면 일반적인 git 충돌이 난다. 마크다운이라
  수동 병합이 쉽다.
- 새 메모리를 쓴 뒤에는 커밋/푸시해야 반대편 머신에 반영된다.
