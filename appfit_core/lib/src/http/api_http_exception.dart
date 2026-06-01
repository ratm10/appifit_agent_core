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

  /// 서버 응답 본문의 `message` (서버 원문).
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
    return ApiHttpException(
      status: err.response?.statusCode,
      method: err.requestOptions.method,
      path: templatePath(raw),
      rawPath: raw,
      code: map['code']?.toString(),
      serverMessage: map['message']?.toString(),
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
