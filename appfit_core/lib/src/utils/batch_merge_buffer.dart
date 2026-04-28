import 'dart:async';

/// 시간 윈도우 기반 배치 머지 타이머의 표준 추상화.
///
/// 다수 이벤트를 짧은 윈도우 안에 누적해 단일 flush 콜백으로 처리하기 위한
/// 공통 패턴. 호출자는 자신의 pending 버퍼(Set/List/Map)를 직접 보관하고,
/// 각 enqueue 지점에서 [schedule]을 호출한다. 윈도우가 지나면 [onFlush]가
/// 호출되어 호출자가 누적된 버퍼를 비우고 단일 state 업데이트를 수행한다.
///
/// 주요 사용처:
/// - DID `OrderNumberNotifier` (200ms 윈도우, 7~12건 일괄 ORDER_DONE 시 단일 rebuild)
/// - appfit_order_agent `OrderQueueManager` (200ms 상태변경 배치)
///
/// 동시 [schedule] 호출은 추가 타이머를 만들지 않으며, 이미 활성 타이머가
/// 있으면 무시한다(window 내 첫 호출이 flush 시점을 결정).
class BatchMergeBuffer {
  final Duration window;
  final void Function() onFlush;

  Timer? _timer;

  BatchMergeBuffer({required this.window, required this.onFlush});

  /// 윈도우 만료 시 [onFlush]가 1회 호출되도록 예약한다.
  /// 이미 활성 타이머가 있으면 무시한다.
  void schedule() {
    if (_timer?.isActive ?? false) return;
    _timer = Timer(window, () {
      _timer = null;
      onFlush();
    });
  }

  /// 예약된 flush 를 즉시 실행한다.
  /// 활성 타이머가 없어도 [onFlush]를 호출한다.
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    onFlush();
  }

  /// 예약된 flush 를 취소한다. [onFlush]는 호출되지 않는다.
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// 현재 활성 타이머가 있는지 (디버깅/테스트용).
  bool get isScheduled => _timer?.isActive ?? false;
}
