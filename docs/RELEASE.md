# 릴리즈 / 빌드 / 테스트

`appfit_core` 패키지의 빌드·테스트·버전 관리·배포 워크플로 참조 문서입니다.

> **저장소 루트가 아니라 `appfit_core/` 디렉토리에서 실행**합니다. 모든 명령어는 `cd appfit_core && ...` 패턴.

## 빌드 및 테스트 명령어

```bash
# 의존성 설치
cd appfit_core && flutter pub get

# 정적 분석
cd appfit_core && flutter analyze

# 전체 테스트 실행 (현재 5개)
cd appfit_core && flutter test

# 단일 테스트 파일 실행
cd appfit_core && flutter test test/<파일_경로>
```

현재 `appfit_core/test/`의 테스트 파일:

- `batch_merge_buffer_test.dart`
- `order_event_ignore_policy_test.dart`
- `processed_order_cache_test.dart`
- `recent_removals_cache_test.dart`
- `socket_event_dispatcher_test.dart`

## 버전 규칙 (Semver)

- **MAJOR**: 공개 API 파괴적 변경 (export 제거/리네임, 추상 인터페이스 시그니처 변경, 메서드 시그니처 변경 등)
- **MINOR**: 하위 호환 기능 추가 (새 export, 새 옵션 파라미터 with 기본값 등)
- **PATCH**: 버그 수정 / 내부 개선 (공개 API 변경 없음)

소비자 앱(appfit_order_agent, DID, kiosk)이 git ref 또는 path로 참조하므로, **breaking change는 양 앱 pubspec.yaml의 ref도 동시 갱신**해야 합니다.

## 배포 절차

1. `appfit_core/pubspec.yaml`의 `version:` 라인 수정 (예: `1.0.8` → `1.0.9`).
2. `CHANGELOG.md`에 새 버전 항목 추가 (변경 요약 + breaking 여부 명시).
3. **드라이런으로 검증**:
   ```bash
   cd appfit_core && bash tool/release.sh --dry-run
   ```
4. 이상이 없으면 실제 배포:
   ```bash
   cd appfit_core && bash tool/release.sh
   ```
5. 공개 API가 변경되었다면 소비자 앱(appfit_order_agent, DID, kiosk) 담당자에게 공지하고, 양 앱 pubspec.yaml의 ref를 새 버전으로 갱신.

## `tool/release.sh` 내부 동작

1. **태그 중복 검사** — `v<VERSION>` 태그가 이미 존재하면 실패
2. **`flutter analyze --no-fatal-infos --no-fatal-warnings`** — error만 실패 처리
3. **`dart tool/sync_version.dart`** — `pubspec.yaml`의 `version:`을 `AppFitConfig.packageVersion` 상수에 자동 동기화
4. **`git commit -m "chore: release v<VERSION>"`**
5. **`git tag v<VERSION>` 생성 후 `origin/main` 및 태그 push**

## 비가역성 경고

`tool/release.sh`는 **git tag push까지 포함**되는 비가역 워크플로입니다.

- 항상 `--dry-run` 먼저 실행
- 잘못된 태그 push 후에는 `git push --delete origin v<VERSION>` 으로만 회수 가능 (소비자 앱이 해당 ref를 이미 fetch했다면 의미 없음)
- 회귀 발생 시 양 앱의 pubspec.yaml `ref`를 이전 버전으로 동시 되돌리기

## 절대 규칙 (재강조)

- **`AppFitConfig.packageVersion` 상수 직접 수정 금지** — `pubspec.yaml`의 `version:` 라인만 수정. `sync_version.dart`가 `release.sh` 안에서 자동 동기화.
- **수동 `git tag` 또는 `flutter pub publish` 직접 호출 금지** — `tool/release.sh`가 단일 진입점.
- **새 공개 API는 `appfit_core/lib/appfit_core.dart`에 export 필수** — 누락 시 소비자 앱에서 import 불가.
