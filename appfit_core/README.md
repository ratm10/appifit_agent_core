# appfit_core

AppFit 매장 운영 앱 군이 공유하는 인프라 SDK.

소비자 앱 (현재 시점):
- **appfit_order_agent** — KDS 주문 라이프사이클 관리 (NEW→PREPARING→READY→DONE, 자동접수, 출력)
- **did** — 주문번호 호출 디스플레이 (preparing ↔ ready 표시 전용)

각 앱은 도메인 로직만 자체 보유하고, 인증·통신·이벤트·모니터링·OTA 등 공통 인프라는
이 패키지를 git 의존성으로 사용한다.

## 의존성

```yaml
dependencies:
  appfit_core:
    git:
      url: https://github.com/ratm10/appifit_agent_core.git
      path: appfit_core
      ref: v1.0.8   # 변경 시 양 앱 동시 업데이트 필요
```

## 카테고리별 export

| 카테고리 | 컴포넌트 | 책임 |
|---|---|---|
| Config | `AppFitConfig`, `AppFitSyncIntervals`, `AppFitTimeouts` | 환경 enum→base URL, 폴링 간격 (60s/10s), 타임아웃 |
| Logging | `AppFitLogger` (인터페이스) | 소비자 앱이 구현체 주입 |
| Auth | `AppFitTokenManager`, `AuthStateProvider`, `CryptoUtils` | JWT, SecureStorage, AES-GCM |
| HTTP | `AppFitDioProvider`, `ApiRoutes` | 인증 인터셉터 + 페이로드 암호화 Dio |
| Socket | `AppFitNotifierService`, `SocketEventDispatcher` | WebSocket 연결 / raw 메시지 분류 |
| Events | `OrderEventType`, `SocketEventPayload`, `OrderEventIgnorePolicy` | 서버 이벤트 enum, payload 값 객체, 무시 정책 |
| Cache | `ProcessedOrderCache`, `RecentRemovalsCache` | 키 단위 dedup (30분 TTL, 500건 LRU) / 종결 부활 차단 (120s TTL) |
| Utils | `BatchMergeBuffer`, `SerialAsyncQueue` (deprecated) | 시간 윈도우 배치, 순차 큐 |
| OTA | `OtaModels`, `OtaUpdateManager` | 버전 비교·다운로드·설치 |
| Monitoring | `MonitoringContext`, `MonitoringService`, `SentryAppFitLogger` | Sentry 컨텍스트 / 초기화 / 로거 |

## v1.0.7 신규 컴포넌트 사용 가이드

### BatchMergeBuffer

시간 윈도우 동안 다수 이벤트를 누적 후 단일 flush 콜백으로 처리.

```dart
final buffer = BatchMergeBuffer(
  window: Duration(milliseconds: 200),
  onFlush: () {
    // pending 버퍼를 비우고 단일 state 업데이트
  },
);

// 각 enqueue 지점에서:
buffer.schedule(); // 활성 타이머 있으면 무시 (window 내 첫 호출이 flush 시점 결정)

// 정리:
buffer.cancel();
```

### ProcessedOrderCache

raw 키 기반 dedup. 키 합성은 호출자가 담당.

```dart
final cache = ProcessedOrderCache(); // 기본 30분 / 500건
final key = '${orderId}_${status}';
if (cache.contains(key)) return;
cache.add(key);
```

### OrderEventIgnorePolicy

도메인 정책 단일 진입점.

```dart
// KDS (appfit_order_agent):
if (OrderEventIgnorePolicy.ignoreNewOrderInKdsMode(isKdsMode) &&
    type == OrderEventType.orderCreated) return;

// DID (디스플레이 전용):
if (OrderEventIgnorePolicy.ignoreForDisplayOnly(eventType)) return;
```

### SocketEventDispatcher

소켓 raw 메시지를 표준화된 `SocketDispatchOutcome` 으로 분류.

```dart
final dispatcher = SocketEventDispatcher(
  resolveStoreId: () => prefs.getStoreId(),
  shouldIgnore: (type, _) => OrderEventIgnorePolicy.ignoreForDisplayOnly(type),
);
final outcome = dispatcher.classify(rawData);
if (outcome.isAccepted) {
  final payload = outcome.payload!;
  // 도메인 후속 처리 (상세 조회 / state 업데이트 / 콜백 등)
}
```

`SocketDispatchKind`: `accepted` / `invalidPayload` / `unknownEventType` /
`ignoredByShopCode` / `ignoredByPolicy`.

## 두 소비자 앱의 활용 차이

| 컴포넌트 | order_agent (KDS) | did (디스플레이) |
|---|---|---|
| BatchMergeBuffer | 자체 OrderQueueManager 3단 파이프라인 사용 | OrderNumberNotifier 200ms flush |
| ProcessedOrderCache | (orderId, status) 키 — 자동접수 race 차단 | (현재 미사용 — inline state checks 로 충분) |
| OrderEventIgnorePolicy | `ignoreNewOrderInKdsMode` | `ignoreForDisplayOnly` |
| SocketEventDispatcher | OrderSocketManager 진입점 | OrderSocketListener 진입점 |
| SocketEventSuppressor | 자가 PUT echo 차단 (자체 구현) | (PUT 안 함) |

## 변경 이력

[CHANGELOG.md](./CHANGELOG.md) 참조.

## 운영 노트

- 본 패키지는 `main` 브랜치에 직접 push, 버전 태그(`vX.Y.Z`)로 릴리스. 두 앱이 git ref 로 참조하므로 **태그를 push 한 후** 양 앱 pubspec.yaml 의 `ref` 를 업데이트한다.
- 회귀 시 양 앱 `ref` 를 이전 버전으로 동시 되돌려야 한다.
- 테스트는 `flutter test` (test/ 디렉토리 참조).
