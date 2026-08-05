# Fleet 채택 가이드

새 앱이 기기 관제(Fleet)를 붙일 때 따라가는 절차 정본입니다. 시스템 전체
(서버·대시보드·D1·명령 수명주기·설계 이력)는 `appfit_order_agent/docs/DEVICE_MONITORING.md`
에 있습니다 — 여기는 **"이 코드베이스에 fleet 을 어떻게 붙이는가"** 만 다룹니다.

## 결정해야 할 3가지

1. **`appType` 문자열** — `FleetAppTypes` 에 상수가 있으면 그걸 쓰고, 없으면
   대문자 스네이크 없는 짧은 이름으로 새로 정한다(예: `'DID'`, `'KIOSK'`).
   서버 D1 의 PK 가 `(app_type, device_id)` 이므로 앱마다 고유해야 한다.
2. **deviceId 출처** — Android 네이티브 시리얼 핸들러가 있는가?
   - 있으면: `nativeSerial:` 로 주입 → `idSource='serial'`.
   - 없으면: 첫 fleet 보고 전에 넣는 것을 강력히 권장한다. 설치 UUID 로
     먼저 띄운 뒤 나중에 시리얼을 붙이면, D1 의 PK 가 `(app_type, device_id)`
     라서 기존 UUID 행이 영구 유령으로 남는다.
3. **`mode` 어휘** — 앱마다 자유(`String?`). 서버는 그대로 TEXT 로 저장만
   한다. 개념이 없으면 아예 생략(null).

## 절차

### 1. `pubspec.yaml`
```yaml
appfit_core:
  git:
    url: https://github.com/ratm10/appifit_agent_core.git
    path: appfit_core
    ref: v1.1.0   # 또는 이후 버전
```

### 2. 목적지 설정 (dart-define)
```dart
// lib/config/app_env.dart (또는 동등한 환경설정 클래스)
static const String fleetBaseUrl = String.fromEnvironment('FLEET_BASE_URL');
static const String fleetDeviceKey = String.fromEnvironment('FLEET_DEVICE_KEY');
```
`.env`(gitignored)에 두 키를 추가하고 기존 `--dart-define-from-file=.env` 빌드
스크립트를 그대로 쓴다. 값이 비어 있으면 `FleetKit` 이 자동으로 `NoopFleetSink`
로 폴백한다 — `hasFleetConfig` 같은 별도 가드는 필요 없다.

### 3. (네이티브 시리얼을 쓴다면) MethodChannel 핸들러
Android 시리얼 조회는 앱마다 재작성해야 한다(Sunmi/일반 기기 API가 다를 수
있음). `appfit_order_agent` 의 `MainActivity` 구현을 참고해 `getDeviceSerial`
핸들러를 추가하고, Dart 쪽에서 `Future<String?> Function()` 형태로 감싼다.

### 4. provider 배선 (riverpod 예시 — 다른 상태관리도 구조는 동일)
```dart
final fleetKitProvider = Provider<FleetKit>((ref) {
  final kit = FleetKit(
    appType: FleetAppTypes.did,           // 결정 ①
    baseUrl: AppEnv.fleetBaseUrl,
    deviceKey: AppEnv.fleetDeviceKey,
    nativeSerial: MyAppSerialReader.read, // 결정 ②, 없으면 생략
    logger: MyAppFitLogger(),
    readAppState: () => FleetAppState(
      storeId: ref.read(myStoreProvider)?.id ?? '',
      storeName: ref.read(myStoreProvider)?.name ?? '',
      mode: null,                         // 결정 ③
    ),
  );
  ref.onDispose(kit.dispose);
  return kit;
});

final fleetSyncProvider = Provider<void>((ref) {
  final kit = ref.watch(fleetKitProvider);
  if (!kit.isRunning) kit.start();

  ref.listen(myStoreProvider, (prev, next) {
    if (next?.id == null || next!.id.isEmpty) return;
    if (next.id == prev?.id) return;
    kit.onStoreChanged();
  });

  ref.listen(mySocketStatusProvider,
      (_, status) => kit.socketConnected = status.isConnected);
});
```
`readAppState` 는 **동기**여야 한다(매 틱 호출). lifecycle/closing/
commandRunning/연결상태 배선은 전부 `FleetKit` 이 소유하므로 여기에 코드가
없다.

### 5. 앱 부팅 지점에서 watch
```dart
// 로그인 화면 이전에도 기기가 관제에 보여야 하므로 화면이 아니라
// 앱 루트 위젯에서 watch 한다.
ref.watch(fleetSyncProvider);
```

### 6. 원격 명령을 지원하지 않는 앱(로그 수집 등)
`commandHandler:` 를 아예 주입하지 않는다. 리포터가 모든 명령에
`UNSUPPORTED` 를 자동 응답한다 — 이게 정답이며 별도 처리가 필요 없다.

### 7. 로거 화이트리스트
파일 로그를 태그 화이트리스트로 거르는 앱이면 `FLEET` 태그를 추가한다.

## 하지 말 것

- **`FleetIdentityResolver` 와 `nativeSerial`/`identityStore` 를 동시에 주입하지
  않는다** — `FleetKit` 생성자가 assert 로 막는다.
- **`sink` 와 `baseUrl`/`deviceKey` 를 동시에 주입하지 않는다** — 마찬가지로
  assert 로 막힌다.
- **fleet 활성화에 `kReleaseMode`/디버그 가드를 걸지 않는다** — 매장 출고본
  에서만 정확히 동작하지 않는, 발견이 가장 늦는 버그 유형이다.
- **`appFitDioProvider` 의 Dio 를 재사용하지 않는다** — 매장 인증 헤더가 관제
  서버로 유출된다. `FleetKit`/`HttpFleetSink` 는 항상 전용 Dio 를 새로 만든다.
- **`FleetRuntime.extra` 를 필터/정렬/알림 대상으로 쓰지 않는다** — 그게
  필요해지면 정식 필드로 승격 요청한다(core PR).
- **설치 UUID 로 먼저 배포한 뒤 나중에 시리얼을 추가하지 않는다** — 결정 ②
  참고.

## 참고 구현

- `appfit_order_agent/lib/providers/fleet_provider.dart` — provider 배선 예시
  (단, 이 앱은 `FleetKit` 이전 전 단계 배선이 남아 있을 수 있음 — CHANGELOG
  v1.1.0 참고)
- `appfit_order_agent/lib/services/monitoring/device_identity_service.dart` —
  네이티브 시리얼 우선순위 참조 구현
