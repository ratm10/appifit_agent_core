import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RecentRemovalsCache', () {
    test('mark 후 contains true, 미등록 id 는 false', () {
      final cache = RecentRemovalsCache();
      cache.mark('O-1');
      expect(cache.contains('O-1'), true);
      expect(cache.contains('O-2'), false);
    });

    test('TTL 만료 후 자동 정리된다', () async {
      final cache = RecentRemovalsCache(
        ttl: const Duration(milliseconds: 50),
      );
      cache.mark('O-1');
      expect(cache.contains('O-1'), true);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cache.contains('O-1'), false);
      expect(cache.size, 0);
    });

    test('snapshotIds 는 만료 정리 후 키 셋 반환', () async {
      final cache = RecentRemovalsCache(
        ttl: const Duration(milliseconds: 50),
      );
      cache.mark('A');
      cache.mark('B');
      expect(cache.snapshotIds(), {'A', 'B'});

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(cache.snapshotIds(), <String>{});
    });

    test('remove 는 명시적으로 제거', () {
      final cache = RecentRemovalsCache();
      cache.mark('X');
      cache.remove('X');
      expect(cache.contains('X'), false);
    });

    test('clear 는 전체 항목 제거', () {
      final cache = RecentRemovalsCache();
      cache.mark('A');
      cache.mark('B');
      cache.clear();
      expect(cache.size, 0);
    });

    test('cleanupExpired 직접 호출 가능', () async {
      final cache = RecentRemovalsCache(
        ttl: const Duration(milliseconds: 30),
      );
      cache.mark('A');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cache.cleanupExpired();
      expect(cache.size, 0);
    });
  });
}
