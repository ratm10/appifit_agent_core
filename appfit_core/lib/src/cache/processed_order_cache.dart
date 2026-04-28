/// 키 단위로 처리됨/소비됨을 추적하여 중복 처리를 차단하는 인메모리 캐시.
///
/// 이중 소스(소켓 ↔ 폴링)에서 동일한 이벤트가 짧은 시간차로 도착하는
/// race 를 차단하기 위해 사용한다. 키 포맷은 호출자가 결정하므로
/// 도메인별로 다음과 같이 합성한다:
/// - appfit_order_agent: `${orderId}_${OrderStatus}` — 같은 (id, status)
///   조합 enqueue 중복 차단, 상태 전이는 통과시키는 sematics.
/// - DID: `${orderId}_${OrderEventType}` — 같은 (id, eventType) 조합 중복 차단.
///
/// TTL/maxSize 는 호출자가 주입할 수 있다(기본 30분 / 500건). 만료 항목과
/// 초과분은 자동 정리한다.
class ProcessedOrderCache {
  /// 키 → 처리 시각.
  final Map<String, DateTime> _processed = {};

  /// 캐시 항목 유효 시간.
  final Duration ttl;

  /// 최대 항목 수. 초과 시 가장 오래된 항목부터 제거.
  final int maxSize;

  ProcessedOrderCache({
    this.ttl = const Duration(minutes: 30),
    this.maxSize = 500,
  });

  /// 키가 이미 처리됨으로 기록되어 있는지.
  /// 호출 시 만료 항목을 자동 정리한다.
  bool contains(String key) {
    _cleanupExpired();
    return _processed.containsKey(key);
  }

  /// 키를 처리됨으로 기록한다.
  /// 항목 수가 [maxSize] 를 넘으면 가장 오래된 항목을 제거한다.
  void add(String key) {
    _cleanupExpired();
    if (_processed.length >= maxSize) {
      final oldest = _processed.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
          .key;
      _processed.remove(oldest);
    }
    _processed[key] = DateTime.now();
  }

  /// 키를 명시적으로 제거한다(예: 처리 실패로 재시도 허용).
  void remove(String key) {
    _processed.remove(key);
  }

  /// 캐시 전체 초기화.
  void clear() {
    _processed.clear();
  }

  /// 디버깅/테스트용 현재 크기.
  int get size => _processed.length;

  void _cleanupExpired() {
    final now = DateTime.now();
    _processed.removeWhere((_, time) => now.difference(time) > ttl);
  }
}
