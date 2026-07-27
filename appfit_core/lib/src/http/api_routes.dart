class ApiRoutes {
  /// 기본 API 버전. 대부분의 엔드포인트는 서버가 v0 만 제공한다.
  static const String version = '/v0';

  /// 서버가 v1 구현을 완료한 엔드포인트 전용 프리픽스.
  ///
  /// 현재 대상은 주문 목록/상세/취소 3개뿐이며(아래 [orders], [orderDetail],
  /// [orderCancel]), 나머지는 v1 이 없으므로 [version] 을 그대로 쓴다.
  /// 런타임 선택축(과거의 로그인 화면 토글)은 없다 — 엔드포인트별로 정적 고정.
  static const String versionV1 = '/v1';
  static const String migrationOptions = '$version/migration/options';

  // Project
  static const String projectInfo = '$version/project/info';

  //Banner
  static const String kioskBanners = '$version/kiosk-banners';
  static const String didBanners = '$version/did-banners';
  //static const String banners = '$version/banners';

  // Shop
  static String shopInfo(String storeId) => '$version/shop/$storeId';
  static String shopOperatingStatus(String storeId) =>
      '$version/shop/$storeId/operating-status';
  static String shopCategories(String storeId) =>
      '$version/shops/$storeId/categories';
  static String shopItemStatus(String storeId) =>
      '$version/shops/$storeId/items/status';
  static String shopOptionStatus(String storeId) =>
      '$version/shops/$storeId/options/status';

  // Order
  // 접수/픽업요청/완료 액션. v1 미제공이라 v0 유지.
  static String orderUpdate(String orderId) => '$version/order/$orderId';

  // 아래 3개만 v1. 목록/취소는 응답 스키마가 v0 과 동일하고, 상세만
  // OrderDetailV1Response 로 달라진다(옵션에 optionGroupPosId 가 실려 라벨
  // sub-info 분류의 정본이 된다).
  static const String orders = '$versionV1/orders';
  static String orderDetail(String orderId) => '$versionV1/orders/$orderId';
  static String orderCancel(String orderId) =>
      '$versionV1/order/$orderId/cancel';

  // 일괄 완료 처리는 v1 미제공이라 v0 유지.
  static const String bulkOrdersDone = '$version/orders/bulk-done';

  // Stamp
  static const String stampEarn = '$version/stamp/earn';
  static const String stampHistory = '$version/stamps/history';
  static const String stampCancel = '$version/stamp/cancel';

  // Coupon
  static String couponValidate(String couponNo) =>
      '$version/coupon/$couponNo/validate';
  static String couponUse(String couponNo) =>
      '$version/coupon/$couponNo/use-without-item';
  static String couponUseCancel(String couponNo) =>
      '$version/coupon/$couponNo/use-cancel';
  static const String couponHistory = '$version/coupons/history';

  // User
  static const String userProfile = '$version/user/profile';
}
