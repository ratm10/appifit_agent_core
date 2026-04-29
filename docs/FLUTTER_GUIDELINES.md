# Flutter 개발 가이드라인

## 코드 스타일 및 네이밍

- **네이밍**: 클래스는 `PascalCase`, 변수/함수/enum 값은 `camelCase`, 파일은 `snake_case`
- **줄 길이**: 80자 이하 권장
- **간결성**: 선언적이고 함수형 패턴을 선호하며, 코드는 명확하면서도 최대한 짧게 작성
- **SOLID 원칙**: 단일 책임, 개방-폐쇄, 리스코프 치환, 인터페이스 분리, 의존성 역전 원칙 적용
- **합성 우선**: 상속보다 합성(composition)을 선호하여 복잡한 로직 구성
- **약어 지양**: 축약어를 피하고, 의미 있고 일관성 있는 이름 사용
- **화살표 함수**: 단순한 한 줄 함수에는 화살표(`=>`) 구문 사용

## Dart 모범 사례

### Null Safety

- Dart의 null safety를 적극 활용하며 sound null-safe 코드 작성
- `!` 연산자는 값이 non-null임이 보장될 때만 사용, 남용 금지
- `int.tryParse()`, `double.tryParse()` 등 안전한 타입 변환 사용

### 비동기 처리

- 비동기 작업에는 `Future`와 `async`/`await`를 사용하고, 반드시 오류 처리 포함
- 비동기 이벤트 시퀀스에는 `Stream` 사용
- UI 스레드 차단을 피하기 위해 무거운 계산은 `compute()`로 별도 Isolate에서 실행

### 패턴 매칭 및 Switch

- 코드를 간결하게 만드는 곳에서 패턴 매칭 활용
- 가능한 경우 exhaustive `switch` 표현식 사용 (`break` 불필요)
- 여러 값을 반환해야 할 때 Record 타입 사용 고려

### 예외 처리

- `try-catch` 블록으로 예외를 처리하고, 상황에 적합한 예외 타입 사용
- 코드가 조용히 실패하지 않도록 에러를 적절히 처리

## Riverpod 사용 규칙

- 새 프로바이더는 `@Riverpod` 어노테이션 + `riverpod_generator` 사용
- 앱 생명주기 동안 유지해야 하는 상태에는 `@Riverpod(keepAlive: true)` 적용
- 비동기 데이터 로딩에는 `AsyncValue` 타입으로 로딩/에러 상태를 명확히 처리
- 프로바이더 생성 후 반드시 `dart run build_runner build --delete-conflicting-outputs` 실행

> 참고: 본 패키지의 `AppFitNotifierNotifier`는 코드 생성 없이 수동 `Notifier` 구현입니다 (소비자 앱에 build_runner 의존성을 강제하지 않기 위함). 신규 Riverpod 컴포넌트도 가능하면 수동 구현을 우선 검토.

## 테스트 가이드라인

- **단위 테스트**: `package:test`로 도메인 로직, 서비스 레이어 테스트
- **패턴**: AAA(Arrange-Act-Assert) 또는 Given-When-Then 패턴 준수
- **Mock 선호도**: Mock보다 Fake/Stub 우선 사용, 필요 시 `mocktail` 활용
- **테스트 실행**: `cd appfit_core && flutter test` 또는 `flutter test test/<파일_경로>`

### 현황 (v1.0.8 기준)

`appfit_core/test/`에 단위 테스트 5개:

- `batch_merge_buffer_test.dart`
- `order_event_ignore_policy_test.dart`
- `processed_order_cache_test.dart`
- `recent_removals_cache_test.dart`
- `socket_event_dispatcher_test.dart`

`dev_dependencies`에 `mocktail` 미포함 (도입 시 추가 필요).

### 테스트 권장 우선순위 (커버리지 확장 시)

1. `auth/token_manager.dart` — 3단계 토큰 전략, 만료 감지, `_refreshingFuture` 동시 401 직렬화
2. `auth/crypto_utils.dart` — AES-256-GCM 왕복, HMAC-SHA512 서명, `isValidAesKey()`
3. `socket/notifier_service.dart` — 지수 백오프, 하트비트, 네트워크 복구 시나리오
4. `http/dio_provider.dart` — shopCode 폴백 우선순위, 401 재시도 경로(`_appfit_retried`)
5. `events/socket_event_payload.dart` — 페이로드 파싱
6. `monitoring/monitoring_service.dart` — 쿨다운/플래핑 상태머신

## CI/CD 현황

- **GitHub Actions**: `.github/workflows/` 미구성 — PR 자동화 없음
- **Pre-commit hooks**: 미설정
- **정적 분석 설정**: `analysis_options.yaml` 미커스터마이즈, `flutter_lints ^3.0.0` 기본값만 사용
- **권장**: PR 시 `flutter analyze` / `flutter test` 자동 실행 워크플로우 도입 검토

## 접근성 (A11Y)

> 본 패키지는 UI를 포함하지 않으므로 접근성 규약은 소비자 앱에서 다룸. 단, 향후 UI 컴포넌트가 추가될 경우:

- **색상 대비**: 텍스트와 배경 간 최소 **4.5:1** 대비율 유지 (WCAG 2.1 기준)
- **시맨틱 레이블**: `Semantics` 위젯으로 UI 요소에 명확한 설명 제공

## 문서화 규칙

- 모든 공개 API에 `///` dartdoc 주석 작성
- 첫 문장은 마침표로 끝나는 간결한 요약
- 복잡하거나 명확하지 않은 코드에만 주석 작성 — 코드 자체로 설명되는 경우 주석 불필요
- 뒤따르는(trailing) 주석 금지
- 코드가 **무엇을** 하는지가 아니라 **왜** 그렇게 하는지 설명
- 공개 추상 인터페이스의 시그니처 변경은 [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)와 [`appfit_core/CHANGELOG.md`](../appfit_core/CHANGELOG.md)에 동시 반영
