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
- 현재 버전: `appfit_core/pubspec.yaml`의 version 라인 참조
- 소비자 앱에서 `path` 의존성으로 참조 (예: `../packages/appfit_core`)

**중요**: 이 패키지는 여러 앱에서 공유하는 공통 패키지입니다. 공개 API 변경 시 모든 소비자 앱에 영향을 미치므로, 기존 API 시그니처 변경에 주의하고 하위 호환성을 고려해야 합니다.

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

- **AppFitConfig** — 환경 enum (`dev`, `staging`, `live`, `japanLive`) 및 base URL/WebSocket URL 결정
- **AppFitTokenManager** — JWT 토큰 3단계 전략: 캐시 → 보안 저장소 → 신규 발급. 만료 감지 및 자동 갱신
- **CryptoUtils** — AES-256-GCM 암호화/복호화, HMAC-SHA512 서명
- **AppFitDioProvider** — 인증 인터셉터 포함 Dio 인스턴스 생성. 401 시 자동 토큰 갱신 및 재시도
- **ApiRoutes** — 버전별 API 엔드포인트 경로 (`/v0`)
- **AppFitNotifierService** — WebSocket 연결 관리. 지수 백오프 재연결 (3초→300초), 하트비트 (30초), 네트워크 복구 감지
- **MonitoringService** — Sentry 싱글톤. 60초 상태 전환 쿨다운, 5분 에러 타입 쿨다운, 플래핑 감지 (5분 내 6회+)
- **AppFitLogger** — 추상 로거 인터페이스. `SentryAppFitLogger`가 에러만 Sentry 전송

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

### 주요 패턴

- **추상 인터페이스**: `AppFitLogger`, `AuthStateProvider`, `MonitoringContext` — 소비자 앱에서 구현
- **싱글톤**: `OtaUpdateManager`, `MonitoringService` — 앱 생명주기 동안 단일 인스턴스
- **의존성 주입**: 로거, 인증 상태 제공자 등을 외부에서 주입
- **데코레이터**: `SentryAppFitLogger`가 기존 로거를 래핑하여 에러만 Sentry로 전송
- **Riverpod Notifier**: `AppFitNotifierNotifier`로 WebSocket 연결 상태 관리

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

### 접근성 (A11Y)

- **색상 대비**: 텍스트와 배경 간 최소 **4.5:1** 대비율 유지 (WCAG 2.1 기준)
- **시맨틱 레이블**: `Semantics` 위젯으로 UI 요소에 명확한 설명 제공

### 문서화 규칙

- 모든 공개 API에 `///` dartdoc 주석 작성
- 첫 문장은 마침표로 끝나는 간결한 요약
- 복잡하거나 명확하지 않은 코드에만 주석 작성 — 코드 자체로 설명되는 경우 주석 불필요
- 뒤따르는(trailing) 주석 금지
- 코드가 **무엇을** 하는지가 아니라 **왜** 그렇게 하는지 설명
