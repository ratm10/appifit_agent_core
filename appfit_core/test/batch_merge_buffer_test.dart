import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BatchMergeBuffer', () {
    test('윈도우 만료 시 onFlush 가 1회 호출된다', () async {
      var calls = 0;
      final buffer = BatchMergeBuffer(
        window: const Duration(milliseconds: 50),
        onFlush: () => calls++,
      );

      buffer.schedule();
      expect(calls, 0);
      expect(buffer.isScheduled, true);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 1);
      expect(buffer.isScheduled, false);
    });

    test('동일 윈도우 내 다중 schedule 은 추가 타이머를 만들지 않는다', () async {
      var calls = 0;
      final buffer = BatchMergeBuffer(
        window: const Duration(milliseconds: 50),
        onFlush: () => calls++,
      );

      buffer.schedule();
      buffer.schedule();
      buffer.schedule();

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 1, reason: '윈도우 내 첫 schedule 만 flush 시점을 결정해야 함');
    });

    test('flushNow 는 활성 타이머를 즉시 실행한다', () async {
      var calls = 0;
      final buffer = BatchMergeBuffer(
        window: const Duration(milliseconds: 200),
        onFlush: () => calls++,
      );

      buffer.schedule();
      buffer.flushNow();
      expect(calls, 1);
      expect(buffer.isScheduled, false);

      // 이후 정상 schedule 가능해야 함
      buffer.schedule();
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(calls, 2);
    });

    test('cancel 은 onFlush 호출 없이 타이머를 해제한다', () async {
      var calls = 0;
      final buffer = BatchMergeBuffer(
        window: const Duration(milliseconds: 50),
        onFlush: () => calls++,
      );

      buffer.schedule();
      buffer.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(calls, 0);
      expect(buffer.isScheduled, false);
    });
  });
}
