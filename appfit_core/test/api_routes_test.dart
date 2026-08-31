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

  // 상태 변경 경로와 프리픽스가 같아서(`/v0/order/{id}`) 오타 하나면 상태 변경
  // PUT 으로 흘러갈 수 있다. 접미사까지 고정한다.
  group('ApiRoutes 픽업 재요청', () {
    const orderNo = '202608310001234567';

    test('orderPickupNoti — 알림 발송 (상태는 안 바뀐다)', () {
      expect(ApiRoutes.orderPickupNoti(orderNo),
          '/v0/order/202608310001234567/pickup-noti');
    });

    test('상태 변경 경로의 하위 경로이되 같지는 않다', () {
      expect(ApiRoutes.orderPickupNoti(orderNo),
          startsWith(ApiRoutes.orderUpdate(orderNo)));
      expect(ApiRoutes.orderPickupNoti(orderNo),
          isNot(equals(ApiRoutes.orderUpdate(orderNo))));
    });
  });
}
