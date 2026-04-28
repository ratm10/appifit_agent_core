/// 최근 종결(DONE/CANCELLED 등) 처리한 주문을 일정 시간 동안 추적하여,
/// 폴링이나 새로고침 응답이 서버 replication lag 으로 해당 주문을 다시
/// 살아있는 상태로 돌려주는 경우의 **부활(재추가)** 을 차단하기 위한 캐시.
///
/// 양 앱 공통 패턴이며, 사용 시나리오는 아래와 같다:
/// - **appfit_order_agent**: `cancelOrder` / `updateOrderStatus(DONE 또는 CANCELLED)`
///   성공 시 [mark] 등록. `refreshOrders` / `_processPollingNewOrders` 진입에서
///   [contains] 로 부활 차단.
/// - **DID**: `removeOrder` 호출 시 [mark] 등록. `_mergeFetchedOrders` 진입에서
///   [contains] 로 부활 차단.
///
/// `ProcessedOrderCache` 와의 차이:
/// - `ProcessedOrderCache` 는 **enqueue 중복 차단** (같은 (id, status) 조합),
/// - `RecentRemovalsCache` 는 **종결 후 부활 차단** (orderId 단독 키).
///
/// 기본 TTL 120초 = 폴링 1사이클(~60초) × 2.
class RecentRemovalsCache {
  /// orderId → 처리 시각.
  final Map<String, DateTime> _entries = {};

  /// 항목 유효 시간.
  final Duration ttl;

  RecentRemovalsCache({this.ttl = const Duration(seconds: 120)});

  /// 종결된 orderId 를 기록한다.
  void mark(String orderId) {
    _entries[orderId] = DateTime.now();
  }

  /// 해당 orderId 가 최근 종결 처리되어 부활 차단 대상인지 확인.
  /// 호출 시 만료 항목을 자동 정리한다.
  bool contains(String orderId) {
    cleanupExpired();
    return _entries.containsKey(orderId);
  }

  /// 만료된 항목을 즉시 제거한다(배치 진입 시 일괄 청소 용도).
  void cleanupExpired() {
    final now = DateTime.now();
    _entries.removeWhere((_, ts) => now.difference(ts) > ttl);
  }

  /// 전체 키 스냅샷. 배치 필터링에 사용.
  Set<String> snapshotIds() {
    cleanupExpired();
    return _entries.keys.toSet();
  }

  /// 명시적 제거(예: 외부에서 부활을 허용하기로 결정한 경우).
  void remove(String orderId) {
    _entries.remove(orderId);
  }

  /// 전체 초기화 (로그아웃 등).
  void clear() {
    _entries.clear();
  }

  /// 디버깅/테스트용 현재 크기.
  int get size => _entries.length;
}
