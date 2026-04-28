import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProcessedOrderCache', () {
    test('add 후 contains true, 미등록 키는 false', () {
      final cache = ProcessedOrderCache();
      cache.add('order1_NEW');
      expect(cache.contains('order1_NEW'), true);
      expect(cache.contains('order1_PREPARING'), false);
      expect(cache.contains('order2_NEW'), false);
    });

    test('TTL 만료 후 자동 정리된다', () async {
      final cache = ProcessedOrderCache(ttl: const Duration(milliseconds: 50));
      cache.add('expiring');
      expect(cache.contains('expiring'), true);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      // contains 호출 시 만료 정리가 실행됨
      expect(cache.contains('expiring'), false);
      expect(cache.size, 0);
    });

    test('maxSize 초과 시 가장 오래된 항목이 제거된다', () async {
      final cache = ProcessedOrderCache(
        ttl: const Duration(hours: 1),
        maxSize: 3,
      );
      cache.add('a');
      // 시간차를 두어 oldest 가 결정되도록 함
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cache.add('b');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cache.add('c');
      expect(cache.size, 3);

      cache.add('d');
      expect(cache.size, 3);
      expect(cache.contains('a'), false, reason: '가장 오래된 a 가 제거됨');
      expect(cache.contains('b'), true);
      expect(cache.contains('c'), true);
      expect(cache.contains('d'), true);
    });

    test('remove 는 키를 명시적으로 제거한다', () {
      final cache = ProcessedOrderCache();
      cache.add('x');
      expect(cache.contains('x'), true);
      cache.remove('x');
      expect(cache.contains('x'), false);
    });

    test('clear 는 전체 항목을 제거한다', () {
      final cache = ProcessedOrderCache();
      cache.add('a');
      cache.add('b');
      cache.add('c');
      expect(cache.size, 3);
      cache.clear();
      expect(cache.size, 0);
      expect(cache.contains('a'), false);
    });
  });
}
