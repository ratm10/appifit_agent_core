# 아키텍처

`appfit_core` 패키지의 내부 구조·주요 클래스·알려진 한계·핵심 설정 상수·공개 추상 인터페이스 시그니처 등 **내부 작업자(Claude/contributor) 시점**의 참조 문서입니다. 외부 사용자(소비자 앱)용 가이드는 [`appfit_core/README.md`](../appfit_core/README.md)를 참조하세요.

## 모듈 구조

```
appfit_core/lib/
├── appfit_core.dart              # 메인 라이브러리 export 파일
└── src/
    ├── auth/                     # 인증 (JWT 토큰 관리, AES-GCM 암호화)
    │   ├── token_manager.dart    # AppFitTokenManager — 토큰 발급/갱신/캐싱
    │   ├── crypto_utils.dart     # AES-256-GCM 암호화, HMAC-SHA512 서명
    │   └── auth_state_provider.dart  # AuthStateProvider 추상 인터페이스 (v1.0.6+)
    ├── cache/                    # 도메인 캐시
    │   ├── processed_order_cache.dart  # 키 단위 dedup (기본 30분 TTL, 500건 LRU)
    │   └── recent_removals_cache.dart  # DONE/CANCELLED 부활 차단 (기본 120s TTL)
    ├── config/                   # 환경 설정
    │   ├── appfit_config.dart    # AppFitConfig — 환경별 URL 결정 (dev/staging/live/japanLive)
    │   ├── appfit_timeouts.dart  # HTTP/WebSocket/OTA 타임아웃 상수
    │   └── sync_intervals.dart   # AppFitSyncIntervals 폴링 간격 상수
    ├── events/                   # 소켓 이벤트
    │   ├── order_event_types.dart        # OrderEventType enum
    │   ├── socket_event_payload.dart     # SocketEventPayload 파싱
    │   ├── order_event_ignore_policy.dart  # 도메인 무시 정책 (KDS / 디스플레이)
    │   └── socket_event_dispatcher.dart    # raw 메시지 → 표준 SocketDispatchOutcome 분류
    ├── http/                     # HTTP 클라이언트
    │   ├── dio_provider.dart     # AppFitDioProvider — Dio 인스턴스 + 인증/로그 인터셉터
    │   └── api_routes.dart       # ApiRoutes — 중앙화된 API 엔드포인트 경로
    ├── logging/                  # 로깅 (v1.0.6+ 분리)
    │   └── appfit_logger.dart    # AppFitLogger 추상 인터페이스 + AppFitLoggerLevels 확장
    ├── monitoring/               # 모니터링
    │   ├── monitoring_service.dart    # Sentry 연동 (쿨다운, 플래핑 감지)
    │   ├── monitoring_context.dart    # MonitoringContext 추상 인터페이스
    │   └── sentry_appfit_logger.dart  # Sentry 로거 데코레이터
    ├── ota/                      # OTA 업데이트
    │   ├── ota_models.dart       # OTA 상태/이벤트 모델
    │   └── ota_update_manager.dart   # APK 다운로드/설치 관리
    ├── socket/                   # WebSocket 통신
    │   ├── notifier_service.dart # AppFitNotifierService — 연결/재연결/하트비트
    │   └── appfit_notifier_notifier.dart  # Riverpod Notifier 래퍼
    └── utils/                    # 유틸리티
        └── serial_async_queue.dart  # SerialAsyncQueue (v1.0.6+ deprecated)
```

## 주요 클래스 및 역할

- **`AppFitConfig`** — 환경 enum (`dev`, `staging`, `live`, `japanLive`) 및 base URL/WebSocket URL 결정. `packageVersion`(자동 동기화), `projectId`, `requestSource` 등 공통 메타데이터 보관.
- **`AppFitTokenManager`** — JWT 토큰 3단계 전략(캐시 → 보안 저장소 → 신규 발급). 만료 감지(`TokenInfo.isExpired`)와 만료 임박 판정(`TokenInfo.isExpiringSoon`, 1시간 여유). 세션 비밀번호 저장/로드/지우기(`savePassword`/`loadPassword`/`clearPassword`)와 프로젝트 자격증명 저장(`saveProjectCredentials`) 및 검증(`validateApiKey`, HMAC-SHA512 서명).
- **`CryptoUtils`** — AES-256-GCM 암호화/복호화(키 길이 부족 시 0바이트 패딩, 초과 시 절삭), HMAC-SHA512 서명 생성. 사전 검증용 `isValidAesKey()` 제공.
- **`AppFitDioProvider`** — 인증 인터셉터 포함 Dio 인스턴스 생성. 401 시 토큰 클리어 후 재발급·재시도 1회. shopCode 폴백 우선순위: `options.extra` → 헤더 → 쿼리 파라미터 → body → URL 경로 → `AuthStateProvider.currentStoreId`.
- **`ApiRoutes`** — 버전별 API 엔드포인트 경로 (`/v0`).
- **`AppFitNotifierService`** — WebSocket 연결 관리. 지수 백오프 재연결(3초→300초, 최대 3회 시도 후 네트워크 복구 이벤트 대기), 하트비트(60초), Ghost Connection 감지(마지막 메시지 5분 이상 시 경고), `connectivity_plus` 기반 네트워크 복구 자동 재연결.
- **`MonitoringService`** — Sentry 싱글톤. 60초 상태 전환 쿨다운, 5분 에러 타입 쿨다운, 플래핑 감지(5분 내 6회+), 플래핑 진입 시 2분 안정화 기간. 성능 트레이싱·자동 세션 트래킹 비활성 상태로 초기화.
- **`AppFitLogger`** — 추상 로거 인터페이스(`logging/appfit_logger.dart`, v1.0.6+ 위치). `log`/`error` 두 메서드만 구현하면 되고, `debug`/`info`/`warn`은 `AppFitLoggerLevels` 확장이 자동 제공(모두 `log` 위임). `SentryAppFitLogger`가 기존 로거를 래핑하여 `error()`만 Sentry로 전달. 기본 구현 `DefaultAppFitLogger`는 `kDebugMode` 가드된 콘솔 출력.
- **`SocketEventDispatcher`** — 소켓 raw 메시지 → 표준화된 `SocketDispatchOutcome` 분류. `SocketDispatchKind`: `accepted`/`invalidPayload`/`unknownEventType`/`ignoredByShopCode`/`ignoredByPolicy`.
- **`OrderEventIgnorePolicy`** — 도메인 정책 단일 진입점. `ignoreNewOrderInKdsMode`(order_agent KDS 모드), `ignoreForDisplayOnly`(DID 디스플레이 전용).
- **`BatchMergeBuffer`** — 시간 윈도우 동안 다수 이벤트 누적 후 단일 flush 콜백. 활성 타이머 있으면 추가 `schedule()` 호출 무시(첫 호출이 flush 시점 결정).
- **`ProcessedOrderCache`** — raw 키 기반 dedup. 키 합성은 호출자 책임(예: `${orderId}_${status}`). 기본 30분 TTL / 500건 LRU.
- **`RecentRemovalsCache`** — DONE/CANCELLED orderId TTL 캐시. 기본 120s. 폴링·초기로드 응답이 살아있는 상태로 돌려줘도 부활 필터링.

## 알려진 한계

코드 작업 시 반드시 알아야 할 비명시적 제약입니다.

- **동시 401 응답 시 토큰 재발급**: v1.0.5+ `AppFitTokenManager`가 `_refreshingFuture`로 발급을 직렬화하여 동시에 401을 받은 여러 요청이 하나의 로그인 API 호출을 공유. `AppFitDioProvider`는 동일 요청당 401 재시도를 1회로 제한(`RequestOptions.extra['_appfit_retried']`). 다만 `clearToken()` 호출 타이밍에 따라 재발급 직전에 새 요청이 들어오면 순간적으로 두 번째 갱신이 발생할 수 있음. 가능하면 소비자 앱 수준에서도 버스트 요청 최소화 권장.
- **비밀번호 평문 보안 저장 가능**: `AppFitTokenManager.savePassword()`는 `FlutterSecureStorage`(iOS Keychain / Android Keystore)에 값을 저장하지만, 저장되는 문자열 자체는 평문. 플랫폼 보안 손상 시 노출 가능. 장기적으로 refresh token 같은 passwordless 전략으로 전환 권장.
- **AES 키 길이 검증은 비엄격**: `CryptoUtils._prepareKey`는 32바이트 미달 시 0바이트 패딩, 초과 시 절삭으로 보정. 디버그 빌드에서는 경고 로그가 출력되며, 사전 검증 시 `CryptoUtils.isValidAesKey()` 사용. 엄격 검증으로의 전환은 운영에서 수신되는 실제 키 길이가 확인된 이후에 고려.
- **`SerialAsyncQueue` Deprecated (v1.0.6+)**: 패키지 내부 사용처가 없어 `@Deprecated` 마킹. 향후 릴리즈에서 제거 예정이므로 사용 중인 소비자 앱은 자체 구현으로 이전 권장.

## 의존성 구조

```
소비자 앱 (appfit_order_agent: path / DID: git ref / kiosk)
    └── appfit_core
            ├── dio (HTTP)
            ├── flutter_riverpod (상태 관리)
            ├── web_socket_channel (WebSocket)
            ├── flutter_secure_storage (보안 저장소)
            ├── connectivity_plus (네트워크 감지)
            ├── sentry_flutter (모니터링)
            ├── encrypt (AES-GCM)
            └── crypto (HMAC-SHA512)
```

## 공개 API export 정책

모든 공개 API는 `appfit_core/lib/appfit_core.dart`에서 export. 새 파일 추가 시 반드시 이 파일에 export 라인을 추가해야 소비자 앱에서 접근 가능.

## 공개 추상 인터페이스 시그니처

소비자 앱이 구현해야 하는 계약. **시그니처가 변경되면 모든 소비자 앱이 영향**을 받으므로 MAJOR bump 검토 필요.

### `AppFitLogger` — `appfit_core/lib/src/logging/appfit_logger.dart` (v1.0.6+, 이전 위치: `auth/token_manager.dart`)

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

기본 구현으로 `DefaultAppFitLogger`(콘솔 출력, `kDebugMode` 가드) 제공. 보통 `await` 없이 fire-and-forget으로 호출됨. 소비자 구현체는 `log`/`error`만 override 하면 호환되며, 레벨별 동작을 분기하려면 `log` 안에서 `[DEBUG]`/`[WARN]` 프리픽스를 파싱.

### `AuthStateProvider` — `appfit_core/lib/src/auth/auth_state_provider.dart` (v1.0.6+, 이전 위치: `http/dio_provider.dart`)

```dart
abstract class AuthStateProvider {
  String? get currentStoreId;
  String? get currentPassword;
}
```

`AppFitDioProvider`에 선택적(`nullable`)으로 주입되어 요청 인터셉터가 shopCode/password를 확보할 때 최종 폴백으로 사용.

### `MonitoringContext` — `appfit_core/lib/src/monitoring/monitoring_context.dart`

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

`MonitoringService.init()` / `updateContext()` 호출 시 Sentry user/tag/context에 매핑.

## 핵심 설정 상수

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
| `ProcessedOrderCache` 기본 TTL/용량 | 30분 / 500건 LRU | `cache/processed_order_cache.dart` |
| `RecentRemovalsCache` 기본 TTL | 120초 | `cache/recent_removals_cache.dart` |

## 주요 패턴

- **추상 인터페이스**: `AppFitLogger`, `AuthStateProvider`, `MonitoringContext` — 소비자 앱에서 구현
- **싱글톤**: `OtaUpdateManager`, `MonitoringService` — 앱 생명주기 동안 단일 인스턴스
- **의존성 주입**: 로거, 인증 상태 제공자 등을 외부에서 주입
- **데코레이터**: `SentryAppFitLogger`가 기존 로거를 래핑하여 에러만 Sentry로 전송
- **Riverpod Notifier**: `AppFitNotifierNotifier`로 WebSocket 연결 상태 관리 (코드 생성 없이 수동 `Notifier` 구현)
- **표준 분류 결과 객체**: `SocketEventDispatcher.classify` → `SocketDispatchOutcome`(`accepted` 외 4종 ignore 사유 명시)
