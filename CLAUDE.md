# CLAUDE.md

## 프로젝트 개요

**appfit_core** — AppFit 매장 운영 앱 군이 공유하는 Flutter 패키지 (인증·소켓·이벤트·캐시·모니터링·OTA).

- 패키지 루트: `appfit_core/` (저장소 루트가 아님 — 모든 명령은 이 디렉토리에서 실행)
- Dart >=3.1.0, Flutter >=3.16.0
- 현재 버전: `appfit_core/pubspec.yaml`의 `version` 라인 참조 (런타임 조회: `AppFitConfig.packageVersion`)
- 소비자 앱: `appfit_order_agent` (path 의존성), `did` (git ref 의존성), `kiosk` 등

## 핵심 명령어

- 의존성/분석/테스트: `cd appfit_core && flutter pub get && flutter analyze && flutter test`
- 릴리즈 드라이런: `cd appfit_core && bash tool/release.sh --dry-run`
- 릴리즈 실배포: `cd appfit_core && bash tool/release.sh`
- 자세한 릴리즈 워크플로: [docs/RELEASE.md](docs/RELEASE.md)

## 절대 규칙

- **공개 API 변경 = breaking 가능성**: `appfit_core/lib/appfit_core.dart` export 라인, 추상 인터페이스(`AppFitLogger`, `AuthStateProvider`, `MonitoringContext`) 시그니처는 변경 시 **모든 소비자 앱**(appfit_order_agent, DID, kiosk) 영향. 변경 시 MAJOR bump 검토 + `CHANGELOG.md` 명시 + 소비자 앱 담당자 공지.
- **`AppFitConfig.packageVersion` 상수 직접 수정 금지** — `appfit_core/pubspec.yaml`의 `version:` 라인만 수정. `tool/sync_version.dart`가 `release.sh` 안에서 자동 동기화.
- **릴리즈는 `tool/release.sh`만 사용** — git tag push 포함 비가역. 수동 `git tag` 또는 `flutter pub publish` 직접 호출 금지.
- **새 공개 클래스 추가 시 export 갱신 필수** — `appfit_core/lib/appfit_core.dart`에 export 라인 추가. 누락 시 소비자 앱에서 import 불가.
- **신규 기능에는 단위 테스트 동반 권장** — 핵심 인프라이므로 `appfit_core/test/`에 추가 (현재 5개 테스트 존재).

## 상세 문서

- 아키텍처(모듈 구조·주요 클래스·알려진 한계·핵심 설정 상수·추상 인터페이스 시그니처·주요 패턴): [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- 릴리즈/버전/빌드/테스트 워크플로: [docs/RELEASE.md](docs/RELEASE.md)
- Flutter/Dart 코드 스타일·null safety·Riverpod·테스트·문서화 규약: [docs/FLUTTER_GUIDELINES.md](docs/FLUTTER_GUIDELINES.md)
- 외부 사용자(소비자 앱) 시점 가이드: [appfit_core/README.md](appfit_core/README.md)
- 변경 이력: [appfit_core/CHANGELOG.md](appfit_core/CHANGELOG.md)
