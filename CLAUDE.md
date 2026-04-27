# CLAUDE.md

이 파일은 Claude Code (claude.ai/code)가 이 저장소에서 작업할 때 참고하는 가이드입니다.

## 언어

모든 아티팩트(task.md, implementation_plan.md, walkthrough.md)와 설명은 항상 **한국어**로 작성합니다.

## AI 상호작용 프로토콜

1. 코드를 작성하기 전에 구현 계획을 먼저 제시하고 사용자의 확인을 받은 후 코드를 생성합니다.
2. 코드 수정 시, 변경된 부분만 보내거나 생략하지 않고, 기존 코드와 동일하더라도 파일의 처음부터 끝까지 완전한 코드를 제공합니다.
3. 다음 정보가 누락되어 코드의 정확성이 저해될 경우, 코드를 생성하지 않고 즉시 정보를 요청합니다:
   - 핵심 컴포넌트 (사용자 정의 클래스, 데이터 모델, Riverpod Provider의 전체 정의)
   - 플랫폼 설정 (build.gradle의 targetSdk, compileSdk 등 필수 사양)
   - 외부 라이브러리 (pubspec.yaml의 라이브러리 명과 정확한 버전)
4. 부정확한 컨텍스트로 코드를 추측하여 완성하지 않습니다.

## 프로젝트 개요

**appfit_core** — AppFit 생태계의 여러 앱(order_agent, DID, kiosk 등)에서 공유하는 인증 및 소켓 통신 공통 인프라 패키지.

- 패키지 이름: `appfit_core`
- Dart SDK: >=3.1.0 <4.0.0, Flutter: >=3.16.0
- 현재 버전: `1.0.4` (`appfit_core/pubspec.yaml` — `tool/sync_version.dart`로 `AppFitConfig.packageVersion` 상수와 자동 동기화됨)
- 런타임 조회: `AppFitConfig.packageVersion` 상수로 소비자 앱에서도 버전 확인 가능
- 소비자 앱에서 `path` 의존성으로 참조

### 소비자 앱 통합

소비자 앱의 `pubspec.yaml`:

```yaml
dependencies:
  appfit_core:
    path: ../packages/appfit_core
```

현재 이 패키지를 사용하는 앱: `order_agent`, `DID`, `kiosk`.

**중요**: 이 패키지는 여러 앱에서 공유하는 공통 패키지입니다. 공개 API 변경 시 모든 소비자 앱에 영향을 미치므로, 기존 API 시그니처 변경에 주의하고 하위 호환성을 고려해야 합니다. 불가피한 breaking change는 릴리즈 노트에 명시하고 소비자 앱 담당자에게 공지합니다.

## 빌드 및 실행 명령어

```bash
# 의존성 설치
cd appfit_core && flutter pub get

# 정적 분석
cd appfit_core && flutter analyze

# 전체 테스트 실행
cd appfit_core && flutter test

# 단일 테스트 파일 실행
cd appfit_core && flutter test test/<파일_경로>
```

## 릴리즈 프로세스

### 버전 규칙

Semver를 따릅니다 (MAJOR.MINOR.PATCH).
- **MAJOR**: 공개 API 파괴적 변경
- **MINOR**: 하위 호환 기능 추가
- **PATCH**: 버그 수정 / 내부 개선

### 배포 절차

1. `appfit_core/pubspec.yaml`의 `version:` 라인을 수정 (예: `1.0.4` → `1.0.5`).
2. 드라이런으로 검증:
   ```bash
   cd appfit_core && bash tool/release.sh --dry-run
   ```
3. 이상이 없으면 실제 배포:
   ```bash
   cd appfit_core && bash tool/release.sh
   ```
4. 공개 API가 변경되었다면 소비자 앱(order_agent, DID, kiosk) 담당자에게 공지합니다.

### `tool/release.sh` 내부 동작

1. 태그 중복 검사 (`v<VERSION>` 이미 존재 시 실패)
2. `flutter analyze --no-fatal-infos --no-fatal-warnings` (error만 실패)
3. `dart tool/sync_version.dart` — `pubspec.yaml` 버전을 `AppFitConfig.packageVersion` 상수에 동기화
4. `git commit -m "chore: release v<VERSION>"`
5. `git tag v<VERSION>` 생성 후 `origin/main` 및 태그 푸시

**주의**: `version:` 라인만 수정하고 `AppFitConfig.packageVersion`은 수동으로 건드리지 말 것. `sync_version.dart`가 자동 동기화합니다.

## 아키텍처

### 모듈 구조

```
appfit_core/lib/
├── appfit_core.dart              # 메인 라이브러리 export 파일
└── src/
    ├── auth/                     # 인증 (JWT 토큰 관리, AES-GCM 암호화)
    │   ├── token_manager.dart    # AppFitTokenManager — 토큰 발급/갱신/캐싱
    │   └── crypto_utils.dart     # AES-256-GCM 암호화, HMAC-SHA512 서명
    ├── config/                   # 환경 설정
    │   ├── appfit_config.dart    # AppFitConfig — 환경별 URL 결정 (dev/staging/live/japanLive)
    │   ├── appfit_timeouts.dart  # HTTP 타임아웃 상수
    │   └── sync_intervals.dart   # 폴링 간격 상수
    ├── http/                     # HTTP 클라이언트
    │   ├── dio_provider.dart     # AppFitDioProvider — Dio 인스턴스 + 인증/로그 인터셉터
    │   └── api_routes.dart       # ApiRoutes — 중앙화된 API 엔드포인트 경로
    ├── socket/                   # WebSocket 통신
    │   ├── notifier_service.dart # AppFitNotifierService — WebSocket 연결/재연결/하트비트
    │   └── appfit_notifier_notifier.dart  # Riverpod Notifier 래퍼
    ├── events/                   # 소켓 이벤트
    │   ├── order_event_types.dart    # OrderEventType enum
    │   └── socket_event_payload.dart # SocketEventPayload 파싱
    ├── ota/                      # OTA 업데이트
    │   ├── ota_models.dart       # OTA 상태/이벤트 모델
    │   └── ota_update_manager.dart   # APK 다운로드/설치 관리
    ├── monitoring/               # 모니터링
    │   ├── monitoring_service.dart    # Sentry 연동 (쿨다운, 플래핑 감지)
    │   ├── monitoring_context.dart   # MonitoringContext 추상 인터페이스
    │   └── sentry_appfit_logger.dart # Sentry 로거 데코레이터
    └── utils/                    # 유틸리티
        └── serial_async_queue.dart   # 순차 비동기 큐
```

### 주요 클래스 및 역할

- **AppFitConfig** — 환경 enum (`dev`, `staging`, `live`, `japanLive`) 및 base URL/WebSocket URL 결정. `packageVersion`, `projectId`, `requestSource` 등 공통 메타데이터 보관
- **AppFitTokenManager** — JWT 토큰 3단계 전략: 캐시 → 보안 저장소 → 신규 발급. 만료 감지(`TokenInfo.isExpired`)와 만료 임박 판정(`TokenInfo.isExpiringSoon`, 1시간 여유) 제공. 세션 비밀번호 저장/로드/지우기(`savePassword`/`loadPassword`/`clearPassword`)와 프로젝트 자격증명 저장(`saveProjectCredentials`) 및 검증(`validateApiKey`, HMAC-SHA512 서명 사용) 포함
- **CryptoUtils** — AES-256-GCM 암호화/복호화(키 길이 부족 시 0바이트 패딩), HMAC-SHA512 서명 생성
- **AppFitDioProvider** — 인증 인터셉터 포함 Dio 인스턴스 생성. 401 시 토큰 클리어 후 재발급·재시도. shopCode는 `options.extra` → 헤더 → 쿼리 파라미터 → body → URL 경로 → `AuthStateProvider.currentStoreId` 순 폴백
- **ApiRoutes** — 버전별 API 엔드포인트 경로 (`/v0`)
- **AppFitNotifierService** — WebSocket 연결 관리. 지수 백오프 재연결 (3초→300초, 최대 3회 시도 후 네트워크 복구 이벤트 대기), 하트비트 (60초), Ghost Connection 감지 (마지막 메시지 5분 이상 시 경고), `connectivity_plus` 기반 네트워크 복구 자동 재연결
- **MonitoringService** — Sentry 싱글톤. 60초 상태 전환 쿨다운, 5분 에러 타입 쿨다운, 플래핑 감지 (5분 내 6회+), 플래핑 진입 시 2분 안정화 기간. 성능 트레이싱·자동 세션 트래킹 비활성 상태로 초기화
- **AppFitLogger** — 추상 로거 인터페이스(`lib/src/logging/appfit_logger.dart`). `log`/`error` 두 메서드만 구현하면 되고, `debug`/`info`/`warn` 은 `AppFitLoggerLevels` 확장이 자동 제공(모두 `log` 위임). `SentryAppFitLogger`가 기존 로거를 래핑하여 `error()`만 Sentry로 전달

### 알려진 한계

- **동시 401 응답 시 토큰 재발급**: v1.0.5부터 `AppFitTokenManager`가 `_refreshingFuture`로 발급을 직렬화하여 동시에 401을 받은 여러 요청이 하나의 로그인 API 호출을 공유합니다. 또한 `AppFitDioProvider`는 동일 요청당 401 재시도를 1회로 제한합니다(`RequestOptions.extra['_appfit_retried']`). 다만 `clearToken()` 호출 타이밍에 따라 재발급 직전에 새 요청이 들어오면 순간적으로 두 번째 갱신이 발생할 수 있으므로, 가능하면 소비자 앱 수준에서도 버스트 요청을 최소화하세요.
- **비밀번호 평문 보안 저장 가능**: `AppFitTokenManager.savePassword()`는 `FlutterSecureStorage`(iOS Keychain / Android Keystore)에 값을 저장하지만, 저장되는 문자열 자체는 평문입니다. 플랫폼 보안 손상 시 노출될 수 있으므로 장기적으로는 refresh token 같은 passwordless 전략으로 전환하는 것을 권장합니다.
- **AES 키 길이 검증은 비엄격**: `CryptoUtils._prepareKey`는 32바이트 미달 시 0바이트 패딩, 초과 시 절삭으로 보정합니다. 디버그 빌드에서는 경고 로그가 출력되며, 사전 검증이 필요할 때는 `CryptoUtils.isValidAesKey()`를 사용하세요. 엄격 검증으로의 전환은 운영에서 수신되는 실제 키 길이가 확인된 이후에 고려합니다.
- **`SerialAsyncQueue` Deprecated (v1.0.6)**: 패키지 내부 사용처가 없어 `@Deprecated` 마킹되었습니다. 향후 릴리즈에서 제거 예정이므로 사용 중인 소비자 앱은 자체 구현으로 이전을 권장합니다.

### 의존성 구조

```
소비자 앱 (order_agent, DID, kiosk)
    └── path: ../packages/appfit_core
            ├── dio (HTTP)
            ├── flutter_riverpod (상태 관리)
            ├── web_socket_channel (WebSocket)
            ├── flutter_secure_storage (보안 저장소)
            ├── connectivity_plus (네트워크 감지)
            ├── sentry_flutter (모니터링)
            ├── encrypt (AES-GCM)
            └── crypto (HMAC-SHA512)
```

### 공개 API export

모든 공개 API는 `appfit_core.dart`에서 export합니다. 새로운 파일을 추가할 경우 반드시 이 파일에 export 라인을 추가해야 소비자 앱에서 접근 가능합니다.

### 공개 추상 인터페이스 시그니처

소비자 앱이 구현해야 하는 계약입니다. 시그니처가 변경되면 모든 소비자 앱이 영향을 받습니다.

**`AppFitLogger`** — `appfit_core/lib/src/logging/appfit_logger.dart` (v1.0.6+, 이전 위치: `auth/token_manager.dart`)
```dart
abstract class AppFitLogger {
  Future<void> log(String message);
  Future<void> error(String message, dynamic error);
}

extension AppFitLoggerLevels on AppFitLogger {
  Future<void> debug(String message); // 'log' 에 위임 ('[DEBUG]' 프리픽스)
  Future<void> info(String message);  // 'log' 에 위임 (프리픽스 없음)
  Future<void> warn(String message);  // 'log' 에 위임 ('[WARN]' 프리픽스)
}
```
기본 구현으로 `DefaultAppFitLogger`(콘솔 출력, 디버그 빌드 한정) 제공. 보통 `await` 없이 fire-and-forget으로 호출됩니다. 소비자 구현체는 `log`/`error` 만 override 하면 호환되며, 레벨별 동작을 분기하려면 `log` 안에서 `[DEBUG]`/`[WARN]` 프리픽스를 파싱하세요.

**`AuthStateProvider`** — `appfit_core/lib/src/auth/auth_state_provider.dart` (v1.0.6+, 이전 위치: `http/dio_provider.dart`)
```dart
abstract class AuthStateProvider {
  String? get currentStoreId;
  String? get currentPassword;
}
```
`AppFitDioProvider`에 선택적(`nullable`)으로 주입되어 요청 인터셉터가 shopCode/password를 확보할 때 최종 폴백으로 사용합니다.

**`MonitoringContext`** — `appfit_core/lib/src/monitoring/monitoring_context.dart`
```dart
abstract class MonitoringContext {
  String get storeId;
  String get storeName;
  String get appType;
  String get appVersion;
  String get buildNumber;
  String get deviceModel;
  String get deviceManufacturer;
  String get environment;
}
```
`MonitoringService.init()` / `updateContext()` 호출 시 Sentry user/tag/context에 매핑됩니다.

### 핵심 설정 상수

| 항목 | 값 | 정의 위치 |
|---|---|---|
| `connectTimeout` / `receiveTimeout` | 15초 | `config/appfit_timeouts.dart` |
| 소켓 연결 시 폴링 주기 | 60초 | `AppFitSyncIntervals.connectedSeconds` |
| 소켓 미연결 시 폴링 주기 | 10초 | `AppFitSyncIntervals.disconnectedSeconds` |
| WebSocket 하트비트 | 60초 | `socket/notifier_service.dart` (`_heartbeatInterval`) |
| Ghost Connection 경고 임계 | 5분 | `socket/notifier_service.dart` |
| 재연결 백오프 | 3초 → 300초 (×2 지수), 최대 3회 시도 | `socket/notifier_service.dart` (`_initialDelaySeconds`, `_maxDelaySeconds`, `_maxReconnectAttempts`) |
| 토큰 만료 임박 여유 | 1시간 | `auth/token_manager.dart` (`TokenInfo.isExpiringSoon`) |
| Sentry 상태 전환 쿨다운 | 60초 | `monitoring/monitoring_service.dart` (`_transitionCooldown`) |
| Sentry 에러 타입 쿨다운 | 5분 | `monitoring/monitoring_service.dart` (`_errorCooldown`) |
| Sentry 플래핑 감지 | 5분 내 6회+ | `monitoring/monitoring_service.dart` (`_flappingThreshold`, `_flappingWindow`) |
| Sentry 플래핑 안정화 | 2분 | `monitoring/monitoring_service.dart` (`_flappingStabilityDuration`) |

### 주요 패턴

- **추상 인터페이스**: `AppFitLogger`, `AuthStateProvider`, `MonitoringContext` — 소비자 앱에서 구현
- **싱글톤**: `OtaUpdateManager`, `MonitoringService` — 앱 생명주기 동안 단일 인스턴스
- **의존성 주입**: 로거, 인증 상태 제공자 등을 외부에서 주입
- **데코레이터**: `SentryAppFitLogger`가 기존 로거를 래핑하여 에러만 Sentry로 전송
- **Riverpod Notifier**: `AppFitNotifierNotifier`로 WebSocket 연결 상태 관리 (현재는 코드 생성 없이 수동 `Notifier` 구현)

---

## Flutter 개발 가이드라인

### 코드 스타일 및 네이밍

- **네이밍**: 클래스는 `PascalCase`, 변수/함수/enum 값은 `camelCase`, 파일은 `snake_case`
- **줄 길이**: 80자 이하 권장
- **간결성**: 선언적이고 함수형 패턴을 선호하며, 코드는 명확하면서도 최대한 짧게 작성
- **SOLID 원칙**: 단일 책임, 개방-폐쇄, 리스코프 치환, 인터페이스 분리, 의존성 역전 원칙 적용
- **합성 우선**: 상속보다 합성(composition)을 선호하여 복잡한 로직 구성
- **약어 지양**: 축약어를 피하고, 의미 있고 일관성 있는 이름 사용
- **화살표 함수**: 단순한 한 줄 함수에는 화살표(`=>`) 구문 사용

### Dart 모범 사례

#### Null Safety
- Dart의 null safety를 적극 활용하며 sound null-safe 코드 작성
- `!` 연산자는 값이 non-null임이 보장될 때만 사용, 남용 금지
- `int.tryParse()`, `double.tryParse()` 등 안전한 타입 변환 사용

#### 비동기 처리
- 비동기 작업에는 `Future`와 `async`/`await`를 사용하고, 반드시 오류 처리 포함
- 비동기 이벤트 시퀀스에는 `Stream` 사용
- UI 스레드 차단을 피하기 위해 무거운 계산은 `compute()`로 별도 Isolate에서 실행

#### 패턴 매칭 및 Switch
- 코드를 간결하게 만드는 곳에서 패턴 매칭 활용
- 가능한 경우 exhaustive `switch` 표현식 사용 (`break` 불필요)
- 여러 값을 반환해야 할 때 Record 타입 사용 고려

#### 예외 처리
- `try-catch` 블록으로 예외를 처리하고, 상황에 적합한 예외 타입 사용
- 코드가 조용히 실패하지 않도록 에러를 적절히 처리

### Riverpod 사용 규칙

- 새 프로바이더는 `@Riverpod` 어노테이션 + `riverpod_generator` 사용
- 앱 생명주기 동안 유지해야 하는 상태에는 `@Riverpod(keepAlive: true)` 적용
- 비동기 데이터 로딩에는 `AsyncValue` 타입으로 로딩/에러 상태를 명확히 처리
- 프로바이더 생성 후 반드시 `dart run build_runner build --delete-conflicting-outputs` 실행

### 테스트 가이드라인

- **단위 테스트**: `package:test`로 도메인 로직, 서비스 레이어 테스트
- **패턴**: AAA(Arrange-Act-Assert) 또는 Given-When-Then 패턴 준수
- **Mock 선호도**: Mock보다 Fake/Stub 우선 사용, 필요 시 `mocktail` 활용
- **테스트 실행**: `flutter test` 또는 `flutter test test/<파일_경로>`

#### 현황

- `appfit_core/test/` 디렉토리 **없음** — 현재 단위 테스트 0개
- `dev_dependencies`에 `mocktail` 미포함 (도입 시 추가 필요)

#### 권장 우선순위 (테스트 구축 시)

1. `auth/token_manager.dart` — 3단계 토큰 전략, 만료 감지
2. `auth/crypto_utils.dart` — AES-256-GCM 왕복, HMAC-SHA512 서명
3. `socket/notifier_service.dart` — 지수 백오프, 하트비트, 네트워크 복구 시나리오
4. `http/dio_provider.dart` — shopCode 폴백 우선순위, 401 재시도 경로
5. `events/socket_event_payload.dart` — 페이로드 파싱
6. `monitoring/monitoring_service.dart` — 쿨다운/플래핑 상태머신

### CI/CD 현황

- **GitHub Actions**: `.github/workflows/` 미구성 — PR 자동화 없음
- **Pre-commit hooks**: 미설정
- **정적 분석 설정**: `analysis_options.yaml` 미커스터마이즈, `flutter_lints ^3.0.0` 기본값만 사용
- **권장**: PR 시 `flutter analyze` / `flutter test` 자동 실행 워크플로우 도입 검토

### 접근성 (A11Y)

- **색상 대비**: 텍스트와 배경 간 최소 **4.5:1** 대비율 유지 (WCAG 2.1 기준)
- **시맨틱 레이블**: `Semantics` 위젯으로 UI 요소에 명확한 설명 제공

### 문서화 규칙

- 모든 공개 API에 `///` dartdoc 주석 작성
- 첫 문장은 마침표로 끝나는 간결한 요약
- 복잡하거나 명확하지 않은 코드에만 주석 작성 — 코드 자체로 설명되는 경우 주석 불필요
- 뒤따르는(trailing) 주석 금지
- 코드가 **무엇을** 하는지가 아니라 **왜** 그렇게 하는지 설명
