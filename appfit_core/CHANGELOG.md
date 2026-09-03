# Changelog

본 패키지는 AppFit 매장 운영 앱 군(KDS, DID 디스플레이, 향후 POS 등)이 공유하는 인프라
SDK 입니다. 각 릴리스는 두 소비자 앱(appfit_order_agent, did)에 동시 영향을 줍니다.

## v1.6.0 (현재) — Windows 식별자에서 MachineGuid 제거

**⚠️ 소스 호환 깨짐: `DefaultFleetIdentityResolver` 생성자에서 `probe` 파라미터를
제거했습니다.** 이 클래스를 직접 만드는 코드는 인자만 지우면 됩니다(`FleetKit`
경유 사용자는 영향 없음 — 파사드가 흡수합니다). MAJOR 가 아닌 이유는 소비 앱에
직접 생성 지점이 하나도 없어서입니다.

### 배경 — 두 매장이 한 기기 행을 나눠 쓰고 있었다

`DefaultFleetIdentityResolver` 는 Windows 식별자로 `AppFitDeviceInfo.windowsMachineGuid`
(= `HKLM\SOFTWARE\Microsoft\SQMClient\MachineId`)를 썼습니다. 이 값은 하드웨어
파생값이 아니라 **OS 설치 이미지에 박혀 있는 값**이라, sysprep 없이 디스크
이미지를 복제해 배포한 POS 들은 전부 같은 값을 갖습니다.

2026-09-03 운영에서 서로 다른 두 매장의 Windows POS 가 같은
`{B4496514-...}` 로 보고해, D1 의 PK `(app_type, device_id)` 한 행을 30초마다
번갈아 덮어썼습니다. 관제 데이터가 무의미해지고, 한 매장은 대시보드에서
사라지고, 원격 명령이 엉뚱한 매장 기기로 배달돼 대상 검증에서 거부됐습니다.
자세한 경위는 `appfit_order_agent/docs/DEVICE_MONITORING.md`.

### Changed
- `DefaultFleetIdentityResolver.resolve()` 의 우선순위가
  **시리얼 > 설치 UUID** 2단이 됐다. Windows 는 기기 정보를 아예 읽지 않고 항상
  설치 UUID 를 쓴다 — 유일성이 `Random.secure` 로 코드에서 보장된다.
- `DefaultFleetIdentityResolver` 가 `AppFitDeviceProbe` 에 의존하지 않는다.
  "기기 정보 조회 실패가 식별자까지 흔든다" 는 결합이 사라졌고, `FleetKit` 이
  `PlatformDeviceProbe` 를 두 번 만들던 중복도 해소됐다.
- `AppFitDeviceInfo.windowsMachineGuid` 는 **유지**하되 용도를 진단 표시용으로
  한정하고, doc 에 식별자 사용 금지 경고를 붙였다. 기존 doc 이 "식별자 후보로
  소비한다" 였어서 그대로 두면 같은 버그를 다시 부른다.
- `FleetIdSources.deviceId` 상수도 **유지**한다. core 는 더 이상 생성하지 않지만
  D1 에 이 값으로 기록된 행이 남아 있어 대시보드가 읽는다.

### Notes
- 소비 앱은 ref 를 올린 뒤 **Windows 기기가 새 device_id 로 재등록**된다. 구
  device 행은 고아가 되므로 롤아웃 완료 후 정리해야 한다.
- `appfit_order_agent` 는 이 resolver 가 아니라 자체
  `DeviceIdentityService` 를 쓴다. 같은 변경을 그쪽에도 적용했다 — 사다리가
  두 곳에 중복 구현돼 있어 한쪽만 고치면 갈라진다.

## v1.3.0 — 매장 카탈로그 중첩 조회 경로 추가

`appfit_order_agent` 의 상품 조회가 `/v0/shops/{shopCode}/categories` 에서
`/categories/items` 로 옮겨갔다. 소비자 앱이 경로 문자열을 직접 조립하고 있어
(`'${ApiRoutes.shopCategories(id)}/items'`) `ApiRoutes` 로 승격한다.

### Added
- `ApiRoutes.shopCategoryItems(storeId)` — `/v0/shops/{storeId}/categories/items`.

  `shopCategories` 와 달리 옵션이 매장 전역 평면 `options[]` 가 아니라 상품별
  `optionGroups[]` 안에 중첩돼 오고, 그룹의 POS 코드(`optionGroupPosId`)가 함께
  온다. 덕분에 옵션의 카테고리 코드를 얻으려고 `/v0/migration/options` 를 한 번 더
  호출해 조인할 필요가 없어진다.

  **주의: 같은 옵션이 상품×그룹마다 반복 등장한다.** 옵션을 평면 목록으로 쓰려는
  소비자는 `optionId` 기준 중복 제거가 필수다 — MMTH00084 실측 기준 원본 4540건이
  고유 148건(30.7배)이었고, 접지 않으면 옵션 모델이 30배로 불어난다.

- `test/api_routes_test.dart` — 매장 카탈로그 계열 경로 문자열 고정. 경로가
  조용히 바뀌면 소비자 앱에서 런타임 404 로만 드러나기 때문이다.

### Notes
- 기존 `shopCategories` / `migrationOptions` 는 그대로 둔다. `did`·`kiosk` 의
  사용 여부를 확인하지 않았고, 상수 제거는 breaking 이다.
- 공개 API 추가만 있고 시그니처 변경은 없다 — 소비자 앱은 ref 를 올리기만 하면 된다.

## v1.2.0 — 소켓 재연결이 더 이상 포기하지 않는다

2026-08-07 PAIK00002(新橋店) 매장 장애 분석의 결론. 인터넷은 끊기지 않았는데
매장 네트워크 상위 경로만 죽는 구간이 14분씩 두 번 있었고, 그동안
`AppFitNotifierService` 는 재연결을 5회(누적 93초) 시도한 뒤 **완전히 멈췄다**.
멈춘 뒤의 복구 경로는 `connectivity_plus` 의 인터페이스 변경 이벤트뿐인데,
Wi-Fi 링크 자체는 멀쩡했으므로 그 이벤트가 영영 오지 않았다 — 앱을 재시작하기
전까지 실시간 주문 수신이 영구히 끊긴다.

코드에 이미 흔적이 있었다: `_maxDelaySeconds = 300` 은 5회 상한(최대 48초) 때문에
**도달 자체가 불가능한 죽은 상수**였다. 원래 의도가 "상한을 둔 무한 재시도"였는데
횟수 제한이 그것을 막고 있었다.

### Changed
- `AppFitNotifierService` 재연결이 **2단계 백오프**가 된다.

  | 구간 | 시도 | 지연 | emit 상태 |
  |---|---|---|---|
  | 빠른 재시도 | 1~5 (0~93초) | 3→6→12→24→48초 | `reconnecting` (기존과 동일) |
  | 전환 시점 | 5회 소진 | — | `disconnected` **1회** + error 로그 |
  | 느린 재시도 | 6회~ **무한** | 300초 고정 | **추가 emit 없음** |
  | 성공 | — | — | `reconnected`, 백오프 3초부터 재시작 |

- **`disconnected` 의 의미가 바뀐다.** 이전에는 "포기했음(더 이상 시도 안 함)"
  이었고, 이제는 "장시간 끊김 — 5분 간격으로 계속 시도 중"이다. 소비자 앱이
  이 상태에 붙여둔 UI(빨간 아이콘, 탭하면 수동 재연결 등)는 그대로 유효하다.
  emit 시점(93초)도 그대로다.
- 느린 구간에서 상태를 다시 emit 하지 않는 이유: 시도마다
  `reconnecting`↔`disconnected` 를 반복하면 앱 UI 가 5분마다 깜빡이고
  `MonitoringService` 의 flapping 감지(5분 내 6회 전환)를 오탐으로 자극한다.
- 전환 로그 문구 교체: `'최대 재연결 횟수 초과. 네트워크 복원 대기.'` →
  `'빠른 재연결 5회 실패 — 300초 간격 재시도로 전환 (계속 시도함)'`.
  기존 문구는 새 동작에서 거짓이다(대기하지 않고 계속 시도한다). Sentry 에서는
  기존 이슈와 다른 그룹으로 잡힌다 — 동작이 실제로 달라졌으므로 의도된 분리다.
- 느린 재시도에서 복귀한 경우 연결 성공 로그에 시도 횟수를 덧붙인다
  (`'연결 성공 (느린 재시도 N번째 시도에서 복구)'`) — 장시간 단절이 자력
  복구됐다는 유일한 증거.
- 느린 구간은 지수 계산(`pow`)을 쓰지 않는다. 무한 재시도에서 지수가 계속
  커지면 `pow(2, 1024)` 가 `double.infinity` 가 되어 `.toInt()` 가 던진다
  (5분 간격이면 약 3.5일 연속 다운에서 도달). 분기 구조상 `pow` 의 지수가
  항상 4 이하로 묶여 오버플로가 구조적으로 불가능해졌다.

### Added
- `AppFitNotifierNotifier.notifyNetworkRestored()` — 코어 서비스의 동명 메서드
  passthrough(순수 가산). 래퍼가 `_coreService` 를 private 으로 감싸고 있어
  앱에서 도달할 수 없던 부분이다. 앱이 다른 경로로 네트워크 복원을 확인했을 때
  (예: HTTP 요청이 다시 성공) 느린 재시도 5분 대기를 건너뛴다. 이미 연결됐거나
  로그아웃 상태면 코어가 무시하므로 호출측 상태 검사가 필요 없다.

### Tests
`notifier_service_reconnect_test.dart` 에 4건 반영 — 백오프 소진 후에도 300초
간격으로 계속 시도(기존 "이후 추가 재시도는 없다" 를 대체), 느린 구간 상태 무 emit,
느린 재시도 중 성공 시 `reconnected` 복귀 + 백오프 3초 재시작, **느린 재시도 중
`disconnect()` 하면 완전히 멈춤**(재시도가 무한이 된 만큼 로그아웃 누수의 대가가
커져 별도로 고정).

### 소비자 앱 영향
- **appfit_order_agent**: `disconnected` 감지 시 HTTP 건강도 회복을 신호로
  소켓을 깨우던 앱 레이어 완화책이 `Auth.reconnect()`(HTTP 왕복 포함) 대신
  `notifyNetworkRestored()` 로 가벼워진다. 역할도 "영구 침묵 탈출"에서
  "5분 대기 단축"으로 바뀐다.
- **did**(v1.1.1 핀): 확인 결과 `disconnected` 를 UI 표시와 폴링 간격 강화(10초)
  에만 쓰고 자체 재연결 루프는 없다 → 코드 변경 없이 동작만 개선된다
  (장시간 끊김에서 자력 복구). emit 시점이 그대로라 폴링 강화 타이밍도 불변.
- **kiosk**: 미확인. `disconnected` 를 "재시도 종료"로 해석해 자체 재연결
  루프를 돌리는 코드가 있으면 코어와 중복 시도가 되므로 채택 전 확인할 것.

## v1.1.1 — FleetKit Noop 오판 수정

v1.1.0 을 DID 실기기(IM-H092)에 처음 붙여보면서 발견: `FLEET_BASE_URL`/
`FLEET_DEVICE_KEY` 미설정 빌드에서도 `FleetKit.connectionStatus` 가
`disabled → connected` 로 전환되는 오판이 있었다. 원인은
`FleetKit` 생성자가 목적지가 `NoopFleetSink` 인지 여부와 무관하게 항상
`ObservingFleetSink` 로 감쌌기 때문 — `NoopFleetSink.register()`/
`heartbeat()` 는 항상 `success:true` 를 돌려주므로, 그 결과를 그대로
관찰하면 "아무것도 전송하지 않는데 연결됨"으로 보인다.

### Fixed
- `FleetKit`: 목적지가 `isConfigured == true` 일 때만 `ObservingFleetSink` 로
  감싼다. Noop 상태에서는 감싸지 않고 그대로 사용 — order_agent 의 기존
  `fleetSinkProvider` 가 원래 갖고 있던 이 조건을 파사드로 옮기며 놓쳤던
  부분. 회귀 테스트 `fleet_kit_test.dart`("Noop 상태에서 connected 로
  오판하지 않는다") 추가.

## v1.1.0 — Fleet 채택 파사드(`FleetKit`)

세 번째 소비 앱(`did`)이 fleet 을 채택하며 드러난 문제: 앱당 채택 비용이
스냅샷 빌더(~110줄)+riverpod 배선(~140줄)+식별자 서비스(~190줄)+연결상태
데코레이터(~70줄)로 ~510줄이었다. 이번 릴리스는 그중 앱 고유가 아닌 부분을
전부 core 로 옮겨 앱당 필수 코드를 ~40줄로 줄인다. **순수 가산(additive)
릴리스** — 기존 `FleetReporter`/`FleetSink`/`HttpFleetSink`/`FleetModels` 공개
API 는 한 글자도 바뀌지 않았고, `fleet_reporter_test.dart` 21케이스는 무수정
통과한다.

### Added
- `src/device/device_probe.dart` — `AppFitDeviceProbe`(추상) + `PlatformDeviceProbe`
  (device_info_plus + package_info_plus 조합, 1회 캐시). fleet 전용이 아니라
  `src/device/` 에 둔 이유: 향후 `MonitoringContext` 구현체들의 중복도 이 probe
  로 흡수할 수 있어서(별도 후속 작업, 인터페이스 자체는 통합하지 않음 — 부팅 시
  1회 스냅샷 vs 60초 주기 live pull 로 시간 의미가 다름).
- `src/fleet/fleet_identity.dart` — `FleetIdentity`/`FleetIdSources`/
  `FleetIdentityResolver`(추상)/`FleetIdentityStore`(추상, 앱 저장소 seam)/
  `PrefsFleetIdentityStore`/`DefaultFleetIdentityResolver`(시리얼 > Windows
  MachineGuid > 설치 UUID, 시리얼 영속 캐시 필수). **"식별자는 소비 앱이
  조달한다"는 기존 규율은 완화되지 않았다** — `identity:` 를 앱이 주입하면
  core 기본 구현은 아예 생성되지 않는 **배타적 슬롯**이다. 앱 정본과 core
  기본이 동시에 존재해 정본이 갈라지는 구조(계층형 폴백)는 만들지 않는다.
- `src/fleet/fleet_app_state.dart` — `FleetAppState`/`FleetAppStateReader`.
  앱이 매 heartbeat 틱마다 돌려주는 유일한 것(storeId/storeName/mode/
  businessOpen/extra). **동기**여야 한다 — I/O 는 이 클로저 밖에서.
- `src/fleet/fleet_snapshot_assembler.dart` — `FleetSnapshotAssembler`.
  order_agent 의 스냅샷 빌더(110줄)를 범용화해 승격. 정적 기기정보·식별자·
  연결성은 기계적으로 조립하고 앱은 `FleetAppStateReader` 하나만 준다.
- `src/fleet/fleet_kit.dart` — `FleetKit` 파사드. 위 전부(식별자·probe·
  연결성·라이프사이클 관찰·sink 조립·연결상태 노출)를 캡슐화하고, 앱은
  `appType` + `readAppState` 만 준다. riverpod provider 는 core 가 만들지
  않는다(2.5/3.0 동시 지원 제약 때문 — 앱이 `Provider` 1~2개로 감싼다).
- `src/fleet/fleet_connection_status.dart`, `src/fleet/observing_fleet_sink.dart`
  — order_agent 전용이던 두 파일(총 72줄)을 두 번째 앱 등장을 계기로 승격.
  `FleetKit` 이 항상 내부에서 `ObservingFleetSink` 로 감싼다.
- `FleetRuntime.extra`(`Map<String, Object?>`, 기본 `const {}`) — 앱 고유 진단
  값의 자유 확장 슬롯. 스칼라 1단계만, 2KB(`FleetRuntime.extraMaxBytes`) 상한
  초과 시 drop+warn(throw 안 함). **`FleetDeviceInfo` 에는 절대 넣지 않는다**
  — 거기 섞이면 `fingerprint` 가 매 틱 달라져 register 가 발화하고 서버의
  boot_count(크래시 루프 지표)가 오염된다.
- `FleetAppTypes`(`orderAgent`/`did`/`kiosk`) — `appType` 편의 상수. **`appType`
  자체는 여전히 `String`** — `FleetCommand.type` 과 같은 이유로 enum 화하지
  않는다(새 앱 추가가 core 재릴리즈를 강제하면 안 됨).
- `docs/FLEET_ADOPTION.md` — 새 앱 채택 절차 정본(7단계 체크리스트).

### Changed
- `FleetRuntime.mode` 주석: "MAIN | KDS. DID/KIOSK 는 null" → "앱별 자유
  어휘. 서버는 TEXT 로 저장만 한다" — 필드 타입(`String?`)은 이미 자유
  어휘를 허용했고, 주석만 실제 규약(DID 의 SIGNAGE/ORDER_NUMBER 등 허용)에
  맞게 바로잡음. 코드 변경 없음.
- `device_info_plus`/`package_info_plus` 의존 범위를 caret(`^`)에서 넓은
  범위(`">=X <Y"`)로 완화 — 공유 SDK 라 소비 앱 3곳의 버전이 갈라질 수 있음.

### ⚠️ order_agent 채택 시 필수 조치 (breaking for one consumer)
`fleet_connection_status.dart`/`observing_fleet_sink.dart` 를 core 가 이제
동일한 이름으로 export 한다. `appfit_order_agent/lib/providers/fleet_provider.dart`
가 `package:appfit_core/appfit_core.dart` 와 로컬 두 파일을 **동시에** import
하므로, ref 를 v1.1.0 으로 올리는 순간 타입이 ambiguous 해져 빌드가 깨진다.
**ref 범프 + 로컬 두 파일 삭제 + import 정리를 반드시 한 커밋에 원자적으로.**
그 외 order_agent 의 기존 배선(`OrderAgentFleetSnapshotBuilder`/
`fleet_provider.dart` 의 provider 6개/`DeviceIdentityService`)은 그대로
유지되며 `FleetKit` 이전은 이번 릴리스 범위가 아니다(후속 PR, 실기기 파일럿
안정화 이후).

## v1.0.18 — 기기 관제(Fleet) 승격

### Added
- `src/fleet/` 신설 — 기기 실행상태·기기정보 보고 + 원격 명령(로그 업로드 등)을
  다루는 공통 리포터. `appfit_order_agent`의 `feat/fleet-monitoring`에서 실기기
  파일럿 전 단계까지 앱 안에서 먼저 구현·검증(fakeAsync 21케이스 + 실서버 왕복
  테스트)한 뒤 그대로 옮긴 것 — 로직 변경 없이 import 경로만 `package:appfit_core/...`
  로 치환됨.
  - `FleetModels`(`FleetDeviceInfo`/`FleetRuntime`/`FleetSnapshot`/`FleetCommand`/
    `FleetAck` 등) — 서버(Cloudflare Worker register/heartbeat) 와이어 계약.
  - `FleetSink`(추상) + `NoopFleetSink` — 전송 목적지 추상화, 미설정 빌드에서
    무해한 기본값.
  - `HttpFleetSink` — 전용 Dio로 관제 서버에 register/heartbeat 전송. **의도적으로
    `appFitDioProvider`를 재사용하지 않는다** — 그 인스턴스는 매장 인증 헤더를
    자동 주입해서, 재사용하면 매장 자격증명이 관제 서버로 흘러간다.
  - `FleetReporter` — 시계를 읽지 않는 순수 Timer 기반 폴링/백오프/명령 디스패치.
    `FleetCommand.type`은 의도적으로 `String`(enum 아님) — 새 명령 타입 추가마다
    core 재릴리즈를 강제하지 않기 위함.
  - `deviceId` 조달·저장은 이 모듈의 책임이 **아니다** — 소비 앱이 콜백으로
    주입한다(order_agent 정본은 `DeviceIdentityService`).

## v1.0.16 — Sentry 노이즈 정리(일시적 네트워크 오류) + 매장명 태그

### Added
- `ApiHttpException.isTransientNetworkError` getter — HTTP 상태코드가 없고
  (`status == null`) Dio 예외 타입이 전송계층 실패(connectionTimeout·sendTimeout·
  receiveTimeout·connectionError·cancel)인 "일시적 네트워크" 오류 판정.
  `DioExceptionType.unknown`·`badCertificate` 는 의도적으로 제외(진짜 결함이
  섞일 수 있어 가시성 유지). 토글 지점은 `_transientDioTypes` 한 곳.
- `MonitoringService`: Sentry scope 에 `store_name` 태그 추가
  (`_applyScope`·`updateStoreInfo` 양쪽). Slack 알림 등에서 **매장명을 바로
  표시**하기 위함 — `user.username`/`store_info` 컨텍스트는 태그가 아니라 알림
  tags 블록에 노출되지 않는다. 매장코드는 기존 `store_id` 태그로 이미 노출.

### Changed
- `SentryAppFitLogger.error`: 일시적 네트워크 오류(HTTP ?)를 Sentry **issue 로
  올리지 않고 breadcrumb(warning)로만** 남긴다. 기기 순단·재연결 중 발생하는
  환경성 오류의 이슈 노이즈를 제거한다. 지속적 장애는 `MonitoringService` 의
  연결 상태 flapping 감지가 별도로 포착한다.

  **소비자 영향 (behavior change)**: 두 앱(appfit_order_agent·did) 모두 순단성
  `ApiHttpException: HTTP ? ...` 오류가 Sentry 이슈로 집계되지 않는다(breadcrumb
  로만 흐름에 기록). 서버 응답이 있는 오류(4xx/5xx)와 지속 장애는 그대로 이슈로
  올라간다. Slack 알림에는 `store_id`(매장코드) + `store_name`(매장명)이 태그로
  표시된다(소비자 앱 재배포 후 신규 이벤트부터).

## v1.0.15 — 운영 로그 1줄화 + 스타일 현대화

### Changed
- 운영 로그 메시지 1줄화 및 코드 스타일 현대화. 동작 변경 없음(로그 출력 포맷만).

## v1.0.14 — 쿠폰 사용 엔드포인트 use-without-item 전환

### Changed
- `ApiRoutes.couponUse(couponNo)`: 반환 경로를 `/v0/coupon/{couponNo}/use` →
  `/v0/coupon/{couponNo}/use-without-item` 로 변경. 신규 엔드포인트는 주문
  아이템 목록 없이 쿠폰을 즉시 사용하므로, 소비자는 요청 바디에서 `items` 필드를
  생략할 수 있다. 메서드 시그니처는 그대로 `String couponUse(String couponNo)`
  (**non-breaking signature, behavior change**).

  **소비자 영향**: `couponUse` 를 호출하는 소비자는 신규 경로/계약으로 자동
  전환된다. did 는 본 라우트를 사용하지 않아 영향 없음. appfit_order_agent 는
  `ApiService.useCoupon` 이 본 라우트를 사용하며 `items` 필드를 제거하도록 동시
  반영. 사전 검증용 `ApiRoutes.couponValidate` 는 그대로 유지(미제거)하나,
  use-without-item 흐름에서는 호출하지 않아도 된다.

## v1.0.13 — 로그인 에러 원본 DioException 보존

### Changed
- `AppFitTokenManager.issueToken()`: 로그인(sign-in) 요청 실패 시 원본
  `DioException` 을 그대로 전파하도록 변경. 과거에는
  `Exception('로그인 API 오류: <msg>')` 평문으로 collapse 해 소비자가 HTTP
  status / 응답 본문(`code`·`message`) / `DioExceptionType` 에 접근하지 못하고
  `e.toString()` 문자열 매칭에 의존해야 했다(네트워크·타임아웃 구분 불가, 서버
  `message` 가 영문 `e.message` 로 대체되는 정보 손실). 메인 Dio 인터셉터와
  동일한 "원본 DioException 전파" 계약으로 통일.

  **소비자 영향 (behavior change, 시그니처는 non-breaking)**: `getValidToken()` /
  `issueToken()` 실패 시 던져지는 예외 타입이 평문 `Exception` →
  `DioException` 으로 바뀐다. `e is DioException` 분기로
  `e.response?.data['message']` / `e.response?.statusCode` / `e.type` 에 직접
  접근 가능. 기존에 예외를 로깅만 하거나 rethrow 하던 소비자(did)는 영향
  없음(`toString()` 은 dio 표준 포맷). appfit_order_agent 는
  `mapDioErrorToApiException` 가 이미 DioException 을 처리.

## v1.0.12 — 토큰 발급 매장 격리 보강 + 테스트 안전망

### Fixed
- `AppFitTokenManager.getValidToken()`: 진행 중(in-flight) 토큰 발급에 다른
  shopCode 요청이 무조건 합류해 남의 매장 토큰을 받던 문제 수정. shopCode 가
  일치할 때만 합류하고, 불일치 시 진행 중 발급 완료를 기다린 뒤 자기 shopCode
  로 새로 발급. 동일 shopCode 동시 요청의 "발급 1회" 보장은 유지.
- `AppFitConfig.packageVersion` 이 1.0.10 으로 남아 있던 동기화 누락 교정
  (v1.0.11 태깅 시 sync_version 단계 누락 추정).

### Added
- `AppFitNotifierService` 생성자에 optional `connector` 파라미터
  (`AppFitWebSocketConnector` typedef) — 테스트에서 실제 네트워크 없이 재연결
  상태머신을 검증하기 위한 seam. 기본값은 기존 `WebSocket.connect` 와 100% 동일
  (하위 호환, 기존 호출부 영향 없음).
- characterization 테스트 66케이스 추가 (CryptoUtils AES-GCM/HMAC,
  ApiHttpException, Dio 401 토큰갱신 재시도, NotifierService 재연결 백오프) —
  총 100케이스.

### Changed
- `analysis_options.yaml` 도입 (flutter_lints + always_use_package_imports),
  상대 import 27건을 package: 로 전환 등 lint 위반 31건 클린업.
- `tool/release.sh` 에 `flutter test` 게이트 추가 ([2/6]) — 테스트 실패 시
  태그 push 전에 릴리즈 중단.

## v1.0.11 — API 오류 모니터링 가독성 보완

### Changed
- API 오류의 Sentry 전송 가독성·추적성 보완 (`ApiHttpException` fingerprint /
  extras 정비). (소급 기록 — 태깅 당시 CHANGELOG 누락)

## v1.0.10 — 토큰 캐시 shopCode 격리

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
