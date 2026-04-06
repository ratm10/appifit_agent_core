/// AppFit HTTP 타임아웃 상수
///
/// 모든 HTTP 요청에서 동일한 타임아웃 값을 사용합니다.
class AppFitTimeouts {
  AppFitTimeouts._();

  /// HTTP 연결 타임아웃 (초)
  static const int connectTimeoutSeconds = 15;

  /// HTTP 응답 타임아웃 (초)
  static const int receiveTimeoutSeconds = 15;

  /// HTTP 연결 타임아웃 Duration
  static const Duration connectTimeout = Duration(seconds: connectTimeoutSeconds);

  /// HTTP 응답 타임아웃 Duration
  static const Duration receiveTimeout = Duration(seconds: receiveTimeoutSeconds);
}
