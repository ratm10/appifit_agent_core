/// 앱이 매 heartbeat 틱마다 [FleetKit] 에 돌려주는 유일한 값 묶음.
///
/// 나머지(정적 기기정보·식별자·연결성·라이프사이클)는 전부 [FleetKit] 이
/// 기계적으로 조립한다. 앱은 storeId/storeName/mode/businessOpen 처럼 자기만
/// 아는 값만 채우면 된다.
class FleetAppState {
  /// 로그인 전에는 빈 문자열. 서버가 "미배정" 버킷으로 분류한다.
  final String storeId;
  final String storeName;

  /// 앱별 자유 어휘(예: ORDER_AGENT 는 MAIN|KDS, DID 는 SIGNAGE|ORDER_NUMBER).
  final String? mode;
  final bool? businessOpen;

  /// [FleetRuntime.extra] 로 그대로 전달되는 진단 확장 값.
  final Map<String, Object?> extra;

  const FleetAppState({
    this.storeId = '',
    this.storeName = '',
    this.mode,
    this.businessOpen,
    this.extra = const {},
  });
}

/// **동기**여야 한다. [FleetKit] 이 매 틱 호출한다 — I/O 를 하면 틱마다
/// 지연이 생기므로, 비동기 조달이 필요한 값은 이 클로저 밖에서 미리 캐시해
/// 두고 여기서는 읽기만 해야 한다.
typedef FleetAppStateReader = FleetAppState Function();
