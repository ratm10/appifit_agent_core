#!/bin/bash
# appfit_core 배포 스크립트
#
# 사용법:
#   cd appfit_core && bash tool/release.sh           # 실제 배포
#   cd appfit_core && bash tool/release.sh --dry-run  # 시뮬레이션만
#
# 전제: pubspec.yaml 버전이 이미 수정되고 코드 변경이 완료된 상태
set -euo pipefail
cd "$(dirname "$0")/.."

# 옵션 파싱
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; fi

# 1. 버전 추출
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
TAG="v$VERSION"

echo ""
echo "=== appfit_core release: $TAG ==="
echo ""

# 2. 중복 태그 확인
if git tag --list | grep -q "^${TAG}$"; then
  echo "ERROR: 태그 $TAG 이(가) 이미 존재합니다. pubspec.yaml 버전을 확인하세요."
  exit 1
fi

# 3. flutter analyze (info/warning은 허용, error만 실패)
echo "[1/6] flutter analyze..."
flutter analyze --no-fatal-infos --no-fatal-warnings
echo ""

# 4. flutter test (실패 시 릴리즈 중단)
echo "[2/6] flutter test..."
flutter test
echo ""

# 5. 버전 동기화 (packageVersion 상수 ← pubspec.yaml)
echo "[3/6] 버전 동기화..."
dart tool/sync_version.dart
echo ""

# 6. 커밋
echo "[4/6] 커밋..."
git add -A .
if git diff --cached --quiet; then
  echo "  변경 사항 없음 — 커밋 생략"
else
  if $DRY_RUN; then
    echo "  [DRY-RUN] git commit -m 'chore: release $TAG'"
    git reset HEAD -- . > /dev/null 2>&1 || true
  else
    git commit -m "chore: release $TAG"
  fi
fi
echo ""

# 7. 태그 생성
echo "[5/6] 태그 생성..."
if $DRY_RUN; then
  echo "  [DRY-RUN] git tag $TAG"
else
  git tag "$TAG"
fi
echo ""

# 8. 푸시
echo "[6/6] 푸시..."
if $DRY_RUN; then
  echo "  [DRY-RUN] git push origin main"
  echo "  [DRY-RUN] git push origin $TAG"
else
  git push origin main
  git push origin "$TAG"
fi

echo ""
echo "=== $TAG 배포 완료 ==="
echo ""
