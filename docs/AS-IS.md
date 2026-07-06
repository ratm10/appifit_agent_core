# appfit_core As-Is 아키텍처

> 버전 0.1 (초판) · 2026-07-06 기준

AppFit 매장 운영 앱군(주문 에이전트·DID·키오스크)이 공유하는 Flutter 패키지 `appfit_core`의 현재(As-Is) 아키텍처 스냅샷이다. **앞선 3개 문서(appfit_order_agent / kokonut / did As-Is)가 "배포되는 앱"을 다뤘다면, 이 문서는 그 앱들 안에 링크되는 "공유 라이브러리"를 다룬다.** 세부 규약의 정본은 [docs/ARCHITECTURE.md](ARCHITECTURE.md)이며, 본 문서는 조감용 요약이다. 시각 모델은 [corec4model/](../corec4model/)(진입점 `c4core-context.html`).

## 0. 이 시스템의 성격 (앞선 3개와 다른 점)

| 구분 | 앱 3종 (order_agent·kokonut·did) | **appfit_core (이 문서)** |
| --- | --- | --- |
| 산출물 | 배포되는 실행 앱(APK·EXE) | **소비자 앱에 링크되는 라이브러리** (독립 실행 없음) |
| "사용자" | 사람(점원·주방·점주) | **소비자 앱**(order_agent·DID·kiosk) — 라이브러리의 진짜 사용자 |
| 하드웨어 | 프린터·Sunmi·VAN 등 | **없음** — device I/O는 소비자 앱 소유 |
| C4 "컨테이너"(L2) | 런타임 실행 단위 | **논리 모듈 그룹**(lib/src/*) — 런타임 컨테이너 아님 |
| 가장 중요한 외부 계약 | UI·기기 | **공개 API·추상 인터페이스 3종**(소비자가 구현) |

## 1. 개요

| 항목 | 내용 |
| --- | --- |
| 패키지명 | `appfit_core` (인증·소켓·이벤트·캐시·모니터링·OTA 공통 인프라) |
| 저장소 | `appifit_agent_core` (로컬: `/Users/kimsungchun/Documents/GitHub/appifit_agent_core`) — 패키지 루트는 저장소 하위 `appfit_core/` |
| 스냅샷 기준 | 브랜치 `feature/remote-log-collection` HEAD (DeviceCommand v1.1.0 이벤트 포함) |
| 언어/SDK | Dart >=3.1.0 · Flutter >=3.16.0 · UI 없음(순수 로직·인프라) |
| 버전 정본 | `appfit_core/pubspec.yaml`의 `version`(현재 `1.1.0`) → `tool/sync_version.dart`가 `AppFitConfig.packageVersion` 상수에 동기화. **런타임 상수는 릴리즈 시점에 갱신**되므로 미릴리즈 브랜치에서는 pubspec과 상수가 다를 수 있음(현재 상수 `1.0.14`) |
| 소비자 앱 | `appfit_order_agent`(path 의존) · `DID`(git ref 의존) · `kiosk` 등 |
| 공개 진입점 | `appfit_core/lib/appfit_core.dart` 단일 export 파일 (새 공개 클래스는 여기 export 필수) |
| 외부 의존 | dio · flutter_riverpod · web_socket_channel · flutter_secure_storage · connectivity_plus · sentry_flutter · encrypt(AES-GCM) · crypto(HMAC) · flutter_downloader · app_installer |
| 릴리즈 | `tool/release.sh` **단일 진입점** (git tag/push·sync_version 자동) — 수동 tag 금지 |

## 2. 모듈 구조 (`lib/src/`)

```
appfit_core/lib/
├── appfit_core.dart          # 공개 API 단일 export
└── src/
    ├── config/               # 환경·URL·타임아웃·폴링 상수
    │   ├── appfit_config.dart       # AppFitConfig · AppFitEnvironment(dev/staging/live/japanLive)
    │   ├── appfit_timeouts.dart      # HTTP/WS/OTA 타임아웃
    │   └── sync_intervals.dart       # 적응형 폴링(60s/15s)
    ├── auth/                 # 인증·암호화
    │   ├── token_manager.dart        # AppFitTokenManager — 3단계 토큰 + 동시발급 직렬화
    │   ├── crypto_utils.dart          # AES-256-GCM · HMAC-SHA512
    │   └── auth_state_provider.dart   # AuthStateProvider 추상 (소비자 구현)
    ├── http/                 # REST 관문
    │   ├── dio_provider.dart          # AppFitDioProvider — 인증/로그 인터셉터
    │   ├── api_routes.dart            # /v0 경로 상수
    │   └── api_http_exception.dart    # 서버 오류 → Sentry 매핑
    ├── socket/               # 실시간 채널
    │   ├── notifier_service.dart       # AppFitNotifierService — 재연결 상태머신
    │   ├── appfit_notifier_notifier.dart  # Riverpod Notifier 래퍼
    │   └── socket_event_dispatcher.dart   # raw → SocketDispatchOutcome 5종
    ├── events/               # 서버-클라이언트 계약
    │   ├── order_event_types.dart · socket_event_payload.dart
    │   ├── order_event_ignore_policy.dart  # 도메인 무시 정책 단일 진입점
    │   └── device_command_types.dart · device_command_payload.dart  # v1.1.0 관재
    ├── cache/                # dedup·부활 차단
    │   ├── processed_order_cache.dart  # 30분 TTL · 500 LRU
    │   └── recent_removals_cache.dart  # 120s 부활 차단
    ├── logging/              # AppFitLogger 추상 + Levels 확장 + Default
    ├── monitoring/           # MonitoringService(Sentry) · MonitoringContext 추상 · SentryAppFitLogger
    ├── ota/                  # OtaUpdateManager(Android APK) · OtaModels
    └── utils/                # BatchMergeBuffer · SerialAsyncQueue(deprecated)
```

## 3. 모듈별 역할 (L2/L3 대응)

| 모듈 | 대표 클래스 | 역할 |
| --- | --- | --- |
| Config | `AppFitConfig` · `AppFitEnvironment` | 환경 enum·base/WebSocket URL·타임아웃·폴링의 단일 정본. 부팅 시 `configure()` 1회 |
| Auth & Crypto | `AppFitTokenManager` · `CryptoUtils` | JWT 3단계 확보(캐시→저장소→발급)·shopCode 격리·동시 401 직렬화. AES-256-GCM·HMAC-SHA512 |
| HTTP | `AppFitDioProvider` | 모든 REST의 단일 관문 — 토큰·Project-ID 자동 주입, 401 재발급·1회 재시도, 오류 구조화 로깅(원본 DioException 전파 계약) |
| Socket & Events | `AppFitNotifierService` · `SocketEventDispatcher` | WSS 재연결 상태머신(backoff·heartbeat·복원) + raw 메시지 5종 분류. 이벤트/정책은 서버 계약으로 응축 |
| Cache & Utils | `ProcessedOrderCache` · `RecentRemovalsCache` · `BatchMergeBuffer` | 이중 소스(소켓↔폴링) dedup·종결 주문 부활 차단·배치 머지. 키 규칙은 호출자 책임 |
| Monitoring & Logging | `MonitoringService` · `AppFitLogger`(추상) · `SentryAppFitLogger` | Sentry 위 노이즈 억제(쿨다운·플래핑) + 로거 데코레이터(error만 Sentry) |
| OTA | `OtaUpdateManager` | Android APK 다운로드·설치(폴링 0.5s·강건성 보정). 버전 JSON/URL은 소비자 주입 |

## 4. 공개 추상 인터페이스 (소비자 구현 계약 — 변경 시 MAJOR bump)

시그니처가 바뀌면 **모든 소비자 앱**(order_agent·DID·kiosk)이 영향받는다.

| 인터페이스 | 위치 | 계약 |
| --- | --- | --- |
| `AppFitLogger` | `logging/appfit_logger.dart` (v1.0.6+) | `log(msg)` / `error(msg, err)` 2메서드. `AppFitLoggerLevels` 확장이 debug/info/warn 자동 제공(모두 log 위임). 기본 구현 `DefaultAppFitLogger`(kDebugMode 콘솔) |
| `AuthStateProvider` | `auth/auth_state_provider.dart` (v1.0.6+) | `currentStoreId` / `currentPassword` getter. DioProvider에 nullable 주입 — shopCode/password 최종 폴백 |
| `MonitoringContext` | `monitoring/monitoring_context.dart` | storeId·storeName·appType·appVersion·buildNumber·deviceModel·deviceManufacturer·environment 8필드 → Sentry user/tag/context 매핑 |

## 5. 핵심 설정 상수

| 항목 | 값 | 정의 위치 |
| --- | --- | --- |
| connect/receive timeout | 30초 | `config/appfit_timeouts.dart` |
| WebSocket 초기 연결 timeout | 20초 | `appfit_timeouts.dart` (`wsConnectTimeout`) |
| WebSocket 프로토콜 ping | 25초 | `appfit_timeouts.dart` (`wsPingInterval`) |
| 하트비트(Ghost 감지) | 60초 | `socket/notifier_service.dart` (`_heartbeatInterval`) |
| Ghost Connection 경고 임계 | 5분 | `appfit_timeouts.dart` (`ghostConnectionThreshold`) |
| 재연결 backoff | 3초 → 300초 (×2 지수), 최대 5회 | `notifier_service.dart` |
| 폴링(소켓 연결/끊김) | 60초 / 15초 | `AppFitSyncIntervals` |
| 토큰 만료 임박 여유 | 1시간 | `token_manager.dart` (`TokenInfo.isExpiringSoon`) |
| Sentry 상태 전환 쿨다운 | 60초 | `monitoring/monitoring_service.dart` |
| Sentry 에러 타입 쿨다운 | 5분 | `monitoring_service.dart` |
| Sentry 플래핑 | 5분 내 6회+ → 2분 안정화 | `monitoring_service.dart` |
| `ProcessedOrderCache` TTL/용량 | 30분 / 500 LRU | `cache/processed_order_cache.dart` |
| `RecentRemovalsCache` TTL | 120초 | `cache/recent_removals_cache.dart` |
| OTA 다운로드 폴링 | 500ms (running 100% 4회 연속 시 완료 처리) | `appfit_timeouts.dart` |
| AES 키 길이 | 32바이트 (비엄격 — 패딩/절삭) | `auth/crypto_utils.dart` |

## 6. 소비자 의존 매트릭스

| 소비자 앱 | 의존 방식 | 비고 |
| --- | --- | --- |
| `appfit_order_agent` | **path** (`../packages/appfit_core` 미러) + 빌드는 **git ref** (`ref: v1.0.15`) | AS-IS(order_agent) 기준. 로컬 path는 미러 사본 |
| `DID` | **git ref** (`github.com/ratm10/appifit_agent_core.git`, path: `appfit_core`) | v1.0.13→v1.0.15 사용 |
| `kiosk` 등 | (프로젝트별) | — |

- **공개 API 변경 = breaking 가능성**: `appfit_core.dart` export 라인·추상 인터페이스 시그니처는 소비자 전원 영향. 변경 시 CHANGELOG 명시 + 소비자 담당자 공지.

## 7. 주요 동작 흐름 (별첨 views 대응)

| 흐름 | 요약 | 뷰 |
| --- | --- | --- |
| 인증 토큰 | 캐시→SecureStorage→발급 3단계. shopCode 격리(매장 전환 시 폐기). 동시 401은 `_refreshingFuture`로 발급 1회 직렬화 + 요청당 `_appfit_retried` 1회 재시도 | `views/c4-auth-token-flow.html` |
| 소켓 생명주기 | 지수 backoff(3→300s·5회) 후 네트워크 복원 대기. 60s 하트비트가 Ghost(readyState≠open) 감지 → 재연결. connectivity 복원 시 즉시 재연결 | `views/c4-socket-lifecycle.html` |
| 이벤트 분류 | raw Map → 파싱·유효성·shopCode·정책 순차 게이트 → `SocketDispatchOutcome` 5종(accepted 외 4 무시/무효). 도메인 후속은 호출자 몫. 기기 명령은 진입 전 분리 | `views/c4-event-dispatch.html` |

## 8. 알려진 한계 (비명시 제약)

| 항목 | 내용 |
| --- | --- |
| 동시 401 재발급 | v1.0.5+ 직렬화(`_refreshingFuture`)로 발급 1회. 다만 `clearToken()` 타이밍에 따라 재발급 직전 새 요청이 들어오면 순간 2회 갱신 가능 — 소비자 측 버스트 최소화 권장 |
| 비밀번호 평문 저장 | `savePassword()`는 SecureStorage(Keychain/Keystore)에 저장하나 **값 자체는 평문** — 플랫폼 보안 손상 시 노출. 장기적으로 passwordless 전환 권장 |
| AES 키 길이 비엄격 | `_prepareKey`가 32B 미달 시 0패딩·초과 시 절삭으로 보정(엔트로피 손실). 디버그 빌드만 경고. 사전검증 `isValidAesKey()` 제공 |
| `SerialAsyncQueue` Deprecated | v1.0.6+ 내부 사용처 없어 `@Deprecated`. 향후 제거 — 사용 중인 소비자 앱은 자체 구현 이전 권장 |
| `BatchMergeBuffer`는 DID 실사용 | 200ms 윈도우 배치 머지로 DID `OrderNumberNotifier`가 사용 — **제거 금지** |

## 9. 릴리즈·버전 (단일 진입점)

| 단계 | 명령 | 동작 |
| --- | --- | --- |
| 분석/테스트 | `cd appfit_core && flutter pub get && flutter analyze && flutter test` | 정적 분석 + 단위 테스트(현재 test/ 10종) |
| 드라이런 | `cd appfit_core && bash tool/release.sh --dry-run` | 실배포 없이 점검 |
| 실배포 | `cd appfit_core && bash tool/release.sh` | `sync_version.dart`가 pubspec version → `AppFitConfig.packageVersion` 동기화 후 git tag/push |

- **🚨 우회 금지**: 수동 `git tag v...` / `git commit -m "chore: release ..."` / `flutter pub publish` 직접 호출 금지. 우회 시 `packageVersion` 동기화 누락(실제 v1.0.10 사고). 상세: [docs/RELEASE.md](RELEASE.md).

## 10. 참고 자료

| 문서 | 내용 |
| --- | --- |
| [docs/ARCHITECTURE.md](ARCHITECTURE.md) | 모듈 구조·주요 클래스·알려진 한계·설정 상수·추상 인터페이스 시그니처(정본) |
| [docs/RELEASE.md](RELEASE.md) | 릴리즈/버전/빌드/테스트 워크플로 |
| [docs/FLUTTER_GUIDELINES.md](FLUTTER_GUIDELINES.md) | 코드 스타일·null safety·Riverpod·테스트·문서화 규약 |
| [appfit_core/README.md](../appfit_core/README.md) | 외부 사용자(소비자 앱) 시점 가이드 |
| [appfit_core/CHANGELOG.md](../appfit_core/CHANGELOG.md) | 변경 이력 |
| [CLAUDE.md](../CLAUDE.md) | 절대 규칙·핵심 명령어 |
| [corec4model/](../corec4model/) | C4 시각 모델 (L1~L4 + views 3종, 진입점 `c4core-context.html`, 검증 `verify_c4.py`) |

C4 모델 개념·작성 규약의 정본은 `appfit_order_agent/docs/C4_GUIDE.md`.
