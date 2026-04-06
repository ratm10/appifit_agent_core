/// AppFit 동기화 간격 상수
///
/// 소켓 연결 상태에 따른 폴링 간격을 공통으로 관리합니다.
/// agent, did 프로젝트 모두 동일한 간격을 사용합니다.
class AppFitSyncIntervals {
  AppFitSyncIntervals._();

  /// 소켓 연결 중 폴링 간격 (1분) - 안전망 역할
  static const int connectedSeconds = 60;

  /// 소켓 단절 시 폴링 간격 (10초) - 보완 역할
  static const int disconnectedSeconds = 10;

  /// 소켓 연결 중 폴링 간격 Duration
  static const Duration connectedInterval = Duration(seconds: connectedSeconds);

  /// 소켓 단절 시 폴링 간격 Duration
  static const Duration disconnectedInterval = Duration(seconds: disconnectedSeconds);
}