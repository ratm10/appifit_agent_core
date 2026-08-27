import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 소비자 앱이 그대로 서버에 쏘는 문자열이라, 경로가 조용히 바뀌면 런타임 404 로만
/// 드러난다. 매장 카탈로그 계열만 최소로 고정한다.
void main() {
  group('ApiRoutes 매장 카탈로그', () {
    const storeId = 'MMTH00084';

    test('shopCategories — 카테고리 + 상품(옵션은 매장 전역 평면 목록)', () {
      expect(
          ApiRoutes.shopCategories(storeId), '/v0/shops/MMTH00084/categories');
    });

    test('shopCategoryItems — 카테고리 + 상품 + 옵션그룹 중첩', () {
      expect(ApiRoutes.shopCategoryItems(storeId),
          '/v0/shops/MMTH00084/categories/items');
    });

    test('shopCategoryItems 는 shopCategories 의 하위 경로다', () {
      expect(ApiRoutes.shopCategoryItems(storeId),
          startsWith(ApiRoutes.shopCategories(storeId)));
    });

    test('상태 변경 경로는 상품/옵션이 분리돼 있다', () {
      expect(ApiRoutes.shopItemStatus(storeId),
          '/v0/shops/MMTH00084/items/status');
      expect(ApiRoutes.shopOptionStatus(storeId),
          '/v0/shops/MMTH00084/options/status');
    });
  });

  // 두 경로는 요청 DTO 가 다른데(기간 vs 주문번호) 서버가 모르는 필드를 조용히
  // 버리므로, 상수를 잘못 고르면 400 이 아니라 "기간 전체 완료" 로 나타난다.
  // 경로가 뒤바뀌는 회귀를 컴파일이 아니라 여기서 잡는다.
  group('ApiRoutes 주문 일괄 완료', () {
    test('bulkOrdersDone — 기간 단위 (READY → DONE)', () {
      expect(ApiRoutes.bulkOrdersDone, '/v0/orders/bulk-done');
    });

    test('forceBulkOrdersDone — 주문번호 지정 강제 완료', () {
      expect(ApiRoutes.forceBulkOrdersDone, '/v0/orders/force/bulk-done');
    });

    test('둘은 서로 다른 경로다', () {
      expect(ApiRoutes.forceBulkOrdersDone,
          isNot(equals(ApiRoutes.bulkOrdersDone)));
    });
  });
}
