# Changelog

본 패키지는 AppFit 매장 운영 앱 군(KDS, DID 디스플레이, 향후 POS 등)이 공유하는 인프라
SDK 입니다. 각 릴리스는 두 소비자 앱(appfit_order_agent, did)에 동시 영향을 줍니다.

## v1.0.10 (현재) — 토큰 캐시 shopCode 격리

### Fixed
- `AppFitTokenManager.getValidToken()`이 메모리·SecureStorage 캐시를 사용할 때
  shopCode 일치 여부를 검증하지 않아, 매장 A 로그인 실패 후 매장 B로 재로그인
  시 A의 토큰이 그대로 반환되어 `/v0/project/info`가 404로 떨어지던 문제 수정.
  - 시나리오: MATA00001 로그인 실패 → TPCP00001 재시도 시 "[Token] 캐시된
    토큰 사용" 로그와 함께 MATA 토큰이 재사용됨. 앱 데이터를 지워야 복구 가능.

### Added
- `TokenInfo.shopCode` (nullable optional 필드) — 토큰이 발급된 매장 식별자를
  보존. 하위 호환: did 등 기존 호출부 시그니처 변경 없음 (기본값 null).
- `_tokenShopCodeKey` (`appfit_jwt_shop_code`) — SecureStorage 키 추가.
  `_saveTokenToStorage` / `_loadTokenFromStorage`가 함께 저장·복원.
- `AppFitTokenManager.getStoredTokenShopCode()` public API — 소비자 앱이 새
  로그인 시도 직전 prefix 전환을 빠르게 감지해 projectId/apiKey/password 등
  토큰 외 자격증명까지 함께 정리할 수 있도록 노출.

### Changed
- `getValidToken()`이 캐시 hit 시 shopCode 일치 검증. mismatch면 폐기 후 새
  발급으로 진행. legacy 토큰(`shopCode == null`)도 mismatch로 간주하여 1회
  재발급으로 자동 마이그레이션 (사용자 노출 오류 없음).
- `_issueAndCache()`가 새 토큰에 shopCode를 주입해 캐시·저장소가 매장
  식별자를 보존.
- `clearToken()`이 `_tokenShopCodeKey`도 함께 삭제.
- 로그 메시지에 shopCode 컨텍스트 추가:
  `[Token] 캐시된 토큰 사용 (shopCode=...)`,
  `[Token] shopCode mismatch — 메모리 캐시 폐기 (cached=..., requested=...)`.

### Migration
- 양 앱 pubspec ref `v1.0.9` → `v1.0.10`.
- 호출부 변경 불필요. `Auth.login()`이 본 PR의 효과를 최대로 활용하려면
  진입부에서 `tokenManager.getStoredTokenShopCode()`로 prefix 전환을 감지해
  projectId/apiKey/password를 함께 정리하는 패턴을 추가 권장 (소비자 앱 측
  변경, appfit_order_agent 본 릴리스에 포함).

---

## v1.0.9 — 설정 상수 튜닝

config(`appfit_config.dart`, `appfit_timeouts.dart`, `sync_intervals.dart`) 및
`notifier_service.dart` 의 운영 상수 조정.

---

## v1.0.8 — 부활 차단 캐시 공통화

### Added
- `RecentRemovalsCache` (`cache/`) — 종결 처리 후 폴링 stale 응답에 의한 부활을
  차단하기 위한 캐시. orderId 단독 키, 기본 TTL 120초. 양 앱 모두 동일 클래스 사용:
  - appfit_order_agent: `cancelOrder` / `updateOrderStatus(DONE/CANCELLED)` 성공 시
    `mark`. `refreshOrders` / `_processPollingNewOrders` 진입에서 `contains` 또는
    `snapshotIds` 로 부활 차단.
  - DID: `removeOrder` 호출 시 `mark`. `_mergeFetchedOrders` 진입에서 `contains` 로
    부활 차단.

### Migration
- 양 앱 pubspec ref `v1.0.7` → `v1.0.8`.
- 양 앱 자체 `_recentRemovals: Map<String, DateTime>` 필드를
  `RecentRemovalsCache` 인스턴스로 교체. 호출 사이트는 inline `removeWhere`/`add`
  → `cleanupExpired`/`mark`/`contains` API 로 마이그레이션.

### Notes
- `OrderStatusMerger` 추출은 보류. 각 앱의 도메인 enum(`OrderStatus` vs
  `OrderNumberStatus`) 이 분리되어 있고, DID 의 머지 로직은 list-level 이므로
  단순 status pair 추상화로 흡수되지 않음. order_agent 는 `_resolveMergedStatus`
  헬퍼를 자체 유지.

---

## v1.0.7 — 주문 흐름 race 가드 공통화

신규 컴포넌트 4종 추가. 양 앱이 동일 추상화로 동작하도록 통합 기반 마련.

### Added
- `BatchMergeBuffer` (`utils/`) — 시간 윈도우 기반 배치 머지 타이머 추상화.
  schedule / flushNow / cancel API. DID OrderNumberNotifier 200ms 윈도우와
  appfit_order_agent OrderQueueManager 200ms 상태변경 배치를 동일 클래스로 사용.
- `ProcessedOrderCache` (`cache/`) — 키 단위 dedup 캐시 (TTL 30분, 500건 LRU).
  키 포맷은 호출자가 결정. appfit_order_agent 는 `${orderId}_${OrderStatus}`,
  DID 는 `${orderId}_${OrderEventType}` (현재 미사용, 추상화로만 보유).
- `OrderEventIgnorePolicy` (`events/`) — 이벤트 무시 정책 단일 진입점.
  - `ignoreNewOrderInKdsMode(bool)` — KDS NEW 차단 (appfit_order_agent)
  - `ignoreForDisplayOnly(OrderEventType)` — DID `ORDER_CREATED/REJECTED` 무시
- `SocketEventDispatcher` (`socket/`) — 소켓 raw 메시지 전처리 베이스.
  파싱 → 페이로드 검증 → shopCode 일치 → 정책 ignore 까지 단일 entrypoint 에서
  분류. 호출자는 `SocketDispatchOutcome.kind` 로 분기하여 도메인 후속 처리만 담당.

### Changed
- `AppFitTokenManager` 보강 — `getStoredApiKey()` / `clearProjectCredentials()` 추가
  (환경 전환·로그아웃 시 자격증명 제거 단일 진입점 마련, appfit_order_agent v3.x).

### Migration
- 양 앱 pubspec ref `v1.0.6` → `v1.0.7`.
- appfit_order_agent: 자체 `ProcessedOrderCache` 가 도메인 래퍼로 변경되어
  내부적으로 본 패키지 클래스를 위임. 호출 API 동일 (`containsOrderStatus` 등).
- DID: `OrderNumberNotifier` 의 `_flushTimer` 가 `BatchMergeBuffer` 인스턴스로 교체.
  schedule/cancel/flushNow API 로 단순화.

---

## v1.0.6 — Project credentials 정리

### Changed
- `AppFitTokenManager` 의 project credentials (projectId / apiKey) 처리 일관화.
- `SerialAsyncQueue` deprecated 표기 (각 소비자 앱이 자체 구현으로 이전).
- `SentryAppFitLogger` 로그 레벨 확장.
- 일부 값 객체에 `==` / `hashCode` / `copyWith` 추가 (불변성 보강).

---

## v1.0.5 — 인터페이스 경로 변경

### Changed
- `AppFitLogger` 인터페이스가 `src/logging/` 으로 이동 (이전 `src/auth/` 에서).
- `AuthStateProvider` 신설 — Riverpod 인증 상태 단일 진입점.

---

## v1.0.4 — 안정화

### Changed
- `_heartbeatInterval` 60초로 조정.
- `pubspec.yaml` description ASCII 화 (Windows CP949 환경 호환).

---

## v1.0.3 이하 — 초기 릴리스

- v1.0.0~v1.0.3: AppFitConfig, TokenManager, DioProvider, AppFitNotifierService,
  CryptoUtils, ApiRoutes, OtaUpdateManager, MonitoringContext 등 기본 인프라
  최초 도입.
