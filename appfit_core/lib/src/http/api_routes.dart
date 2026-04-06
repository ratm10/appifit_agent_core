class ApiRoutes {
  static const String version = '/v0';
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
  static String orderUpdate(String orderId) => '$version/order/$orderId';
  static String orderDetail(String orderId) => '$version/orders/$orderId';
  static String orderCancel(String orderId) => '$version/order/$orderId/cancel';
  static const String orders = '$version/orders';
  static const String bulkOrdersDone = '$version/orders/bulk-done';

  // Stamp
  static const String stampEarn = '$version/stamp/earn';
  static const String stampHistory = '$version/stamps/history';
  static const String stampCancel = '$version/stamp/cancel';

  // Coupon
  static String couponValidate(String couponNo) =>
      '$version/coupon/$couponNo/validate';
  static String couponUse(String couponNo) => '$version/coupon/$couponNo/use';
  static String couponUseCancel(String couponNo) =>
      '$version/coupon/$couponNo/use-cancel';
  static const String couponHistory = '$version/coupons/history';

  // User
  static const String userProfile = '$version/user/profile';
}
