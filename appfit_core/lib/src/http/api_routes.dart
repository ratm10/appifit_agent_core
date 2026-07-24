import 'package:appfit_core/src/config/appfit_config.dart';

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

  // orderCancel 만 런타임 버전 전환 대상이다. 현재 서버 구현 상태상 취소
  // 엔드포인트만 v1 대응이 필요해, 로그인 화면 토글(AppFitConfig.apiVersion)을
  // 따른다. 나머지 라우트는 전부 /v0 고정.
  static String orderCancel(String orderId) =>
      '${AppFitConfig.apiVersion}/order/$orderId/cancel';
  static const String orders = '$version/orders';
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
