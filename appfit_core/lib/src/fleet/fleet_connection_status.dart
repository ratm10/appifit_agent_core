/// 기기 관제(Fleet) 연결 상태. 설정화면/앱바 아이콘 등 UI 표시용.
///
/// [FleetReporter] 는 이 상태를 직접 노출하지 않는다(내부 실패 카운터는
/// private). [FleetKit] 이 [ObservingFleetSink] 로 register/heartbeat 결과를
/// 관찰해 이 값을 유도해 [FleetKit.connectionStatus] 로 노출한다.
enum FleetConnectionStatus {
  /// 목적지 설정 미주입 — 관제 자체가 꺼져 있음.
  disabled,

  /// 설정은 있으나 register/heartbeat 응답을 아직 한 번도 받지 못함.
  connecting,

  /// 최근 보고가 성공.
  connected,

  /// 최근 보고가 실패(오프라인·서버 오류·타임아웃 등).
  error,
}
