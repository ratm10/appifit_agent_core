import 'dart:async';
import 'dart:collection';

/// 범용 순차 비동기 큐
///
/// 비동기 작업을 순차적으로 처리합니다.
/// 이전 작업이 완료되어야 다음 작업이 시작됩니다.
///
/// 사용 예:
/// - 프린트/TTS 출력 순차 처리 (agent: OutputQueueService)
/// - 애니메이션 순차 처리 (did: PreparingListWidget)
class SerialAsyncQueue<T> {
  final Queue<T> _queue = Queue();
  bool _isProcessing = false;

  /// 작업 처리 콜백
  final Future<void> Function(T item) onProcess;

  /// 에러 처리 콜백 (optional)
  final void Function(T item, Object error, StackTrace stack)? onError;

  SerialAsyncQueue({required this.onProcess, this.onError});

  /// 큐에 아이템 추가 후 처리 시작
  void add(T item) {
    _queue.add(item);
    _processNext();
  }

  /// 여러 아이템을 큐에 추가
  void addAll(Iterable<T> items) {
    _queue.addAll(items);
    _processNext();
  }

  /// 큐 내 대기 아이템 수
  int get length => _queue.length;

  /// 처리 중인지 여부
  bool get isProcessing => _isProcessing;

  /// 큐가 비어있고 처리 중이 아닌지
  bool get isIdle => _queue.isEmpty && !_isProcessing;

  /// 큐 전체 비우기
  void clear() {
    _queue.clear();
    _isProcessing = false;
  }

  Future<void> _processNext() async {
    if (_isProcessing) return;
    if (_queue.isEmpty) return;

    _isProcessing = true;
    final item = _queue.removeFirst();

    try {
      await onProcess(item);
    } catch (e, stack) {
      onError?.call(item, e, stack);
    } finally {
      _isProcessing = false;
      if (_queue.isNotEmpty) {
        // 스택 오버플로우 방지를 위해 microtask로 다음 처리 예약
        Future.microtask(() => _processNext());
      }
    }
  }
}
