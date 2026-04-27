/// AppFit 타임아웃 / 폴링 / 임계값 상수.
///
/// HTTP·WebSocket·OTA 등 시간 관련 매직 넘버를 한 곳에서 관리합니다.
class AppFitTimeouts {
  AppFitTimeouts._();

  // --- HTTP ---

  /// HTTP 연결 타임아웃 (초).
  static const int connectTimeoutSeconds = 15;

  /// HTTP 응답 타임아웃 (초).
  static const int receiveTimeoutSeconds = 15;

  /// HTTP 연결 타임아웃 Duration.
  static const Duration connectTimeout =
      Duration(seconds: connectTimeoutSeconds);

  /// HTTP 응답 타임아웃 Duration.
  static const Duration receiveTimeout =
      Duration(seconds: receiveTimeoutSeconds);

  // --- WebSocket ---

  /// WebSocket 초기 연결 타임아웃.
  static const Duration wsConnectTimeout = Duration(seconds: 10);

  /// WebSocket 프로토콜 ping 주기 (서버 pong 미응답 시 onDone 자동 발화).
  static const Duration wsPingInterval = Duration(seconds: 25);

  /// WebSocket "Ghost Connection" 경고 임계 — 마지막 메시지 수신 후 이만큼
  /// 메시지가 없으면 의심 신호로 간주.
  static const Duration ghostConnectionThreshold = Duration(minutes: 5);

  // --- OTA ---

  /// OTA 다운로드 진행률 폴링 주기.
  static const Duration otaPollingInterval = Duration(milliseconds: 500);

  /// OTA running 상태에서 progress 100% 가 이만큼 연속으로 보고되면 완료로 처리
  /// (일부 Android 기기에서 complete 상태 미보고 대응).
  static const int otaRunningAt100Threshold = 4;
}
