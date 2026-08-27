import 'package:dio/dio.dart';

/// HTTP 오류를 사람이 읽기 쉬운 형태로 표현하는 예외.
///
/// **Sentry 캡처/로깅 전용**으로 사용한다. 호출부에는 원본 [DioException] 이
/// 그대로 전파되므로(`handler.next(err)`), 소비자 앱의 `e is DioException`
/// 분기 로직은 영향을 받지 않는다.
///
/// `toString()` 이 Sentry 이슈 타이틀로 그대로 노출된다. 예:
/// `HTTP 400 PUT /v0/order/{id} · INVALID_ORDER_STATUS · 이미 픽업 요청된 주문입니다.`
class ApiHttpException implements Exception {
  /// HTTP 상태 코드 (응답 없으면 null).
  final int? status;

  /// HTTP 메서드 (GET/POST/PUT...).
  final String method;

  /// 그룹핑용 템플릿 경로 — 숫자/긴 식별자 세그먼트를 `{id}` 로 치환.
  final String path;

  /// 원본 요청 경로 (식별자 포함).
  final String rawPath;

  /// 서버 응답 본문의 `code` (예: `INVALID_ORDER_STATUS`).
  final String? code;

  /// 서버 응답 본문의 `message`.
  ///
  /// **6자리 이상 숫자열이 마스킹된 상태로 보관된다** ([redactDigitRuns]).
  /// 서버가 입력값을 그대로 되돌려주는 메시지(`Invalid couponNo: 01092337380`)가
  /// 있어서, 원문을 그대로 두면 [toString] 을 통해 Sentry 이슈 제목 → Slack
  /// 알림까지 고객 전화번호가 흘러갔다. 원문이 필요한 호출부(사용자 노출
  /// 다이얼로그 등)는 `cause.response?.data['message']` 를 직접 읽는다.
  final String? serverMessage;

  /// 추적용 요청 ID (`x-request-id` 헤더).
  final String? requestId;

  /// 원본 Dio 예외 (스택/응답 보존).
  final DioException cause;

  ApiHttpException({
    required this.status,
    required this.method,
    required this.path,
    required this.rawPath,
    required this.code,
    required this.serverMessage,
    required this.requestId,
    required this.cause,
  });

  /// 6자리 이상 연속 숫자. 전화번호(9~11자리)·쿠폰번호(16자리)·주문번호(18자리)를
  /// 덮으면서 상태코드·개수·연도 같은 짧은 숫자는 건드리지 않는 하한이다.
  static final RegExp _digitRun = RegExp(r'\d{6,}');

  /// 6자리 이상 숫자열을 같은 길이의 `*` 로 치환한다.
  /// `Invalid couponNo: 01092337380` -> `Invalid couponNo: ***********`
  ///
  /// [templatePath] 가 경로의 긴 식별자를 `{id}` 로 지우는 것과 같은 정책을,
  /// 식별자가 실려 오는 다른 통로인 서버 `message` 에 적용한 것이다. 길이를
  /// 보존하는 이유는 자릿수가 진단 단서이기 때문이다 — 11자리면 전화번호,
  /// 16자리면 쿠폰번호를 잘못 넣었다는 뜻이라 값 없이도 원인이 잡힌다.
  ///
  /// 앱 쪽에서 같은 서버 메시지를 로그/breadcrumb 으로 남길 때도 이 함수를 쓴다
  /// (규칙이 두 벌로 갈라지면 한쪽만 새는 구멍이 생긴다).
  static String redactDigitRuns(String value) =>
      value.replaceAllMapped(_digitRun, (m) => '*' * m[0]!.length);

  /// orderId 등 숫자/긴 식별자 세그먼트를 `{id}` 로 치환해 그룹핑을 안정화한다.
  /// 예: `/v0/order/849083306090384177` -> `/v0/order/{id}`
  static String templatePath(String path) {
    return path
        .split('/')
        .map((seg) => RegExp(r'^\d{3,}$').hasMatch(seg) ? '{id}' : seg)
        .join('/');
  }

  /// [DioException] 으로부터 서버 본문(`code`/`message`)을 추출해 생성한다.
  factory ApiHttpException.fromDio(DioException err) {
    final body = err.response?.data;
    final map = body is Map ? body : const <dynamic, dynamic>{};
    final raw = err.requestOptions.path;
    final rawMessage = map['message']?.toString();
    return ApiHttpException(
      status: err.response?.statusCode,
      method: err.requestOptions.method,
      path: templatePath(raw),
      rawPath: raw,
      code: map['code']?.toString(),
      // 생성 시점에 마스킹한다 — 이 객체가 닿는 곳(toString/toExtras/breadcrumb)
      // 전부가 Sentry 행이라, 출력 지점마다 거는 방식은 하나만 빠뜨려도 샌다.
      serverMessage: rawMessage == null ? null : redactDigitRuns(rawMessage),
      requestId: err.response?.headers.value('x-request-id'),
      cause: err,
    );
  }

  /// Sentry 태그/컨텍스트로 승격할 구조화 데이터.
  Map<String, dynamic> toExtras() => <String, dynamic>{
        'http.method': method,
        'http.path': path,
        'http.status': status,
        if (code != null) 'server.code': code,
        if (serverMessage != null) 'server.message': serverMessage,
        if (requestId != null) 'request_id': requestId,
      };

  /// 서버 응답 없이 전송 계층에서 실패한 "일시적 네트워크" 오류인지.
  ///
  /// 기기 순단·재연결 중 발생하는 환경성 오류로, HTTP 상태코드가 없고
  /// (`status == null`) Dio 예외 타입이 연결/타임아웃/취소 계열이다.
  /// Sentry issue 로 올리지 않고 breadcrumb 으로만 남기는 판정에 쓰인다
  /// ([SentryAppFitLogger.error] 참고). 지속적 장애는 별도로
  /// `MonitoringService` 의 연결 상태 flapping 감지가 포착한다.
  ///
  /// `DioExceptionType.unknown` 은 의도적으로 제외한다 — 미분류 오류에
  /// 진짜 결함이 섞여 들어올 수 있어 issue 로 남겨 가시성을 유지한다.
  /// 새 타입 토글은 [_transientDioTypes] 한 곳만 수정한다.
  bool get isTransientNetworkError =>
      status == null && _transientDioTypes.contains(cause.type);

  /// 서버 응답 없는 전송 계층 실패로 간주할 Dio 예외 타입.
  static const Set<DioExceptionType> _transientDioTypes = {
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.connectionError,
    DioExceptionType.cancel,
  };

  /// Sentry 그룹핑 fingerprint — 메서드+경로+상태+서버코드 단위로 묶는다.
  List<String> get fingerprint => <String>[
        'http',
        method,
        path,
        '${status ?? '?'}',
        if (code != null) code!,
      ];

  @override
  String toString() {
    final parts = <String>[
      'HTTP ${status ?? '?'} $method $path',
      if (code != null) code!,
      if (serverMessage != null && serverMessage!.isNotEmpty) serverMessage!,
    ];
    return parts.join(' · ');
  }
}
