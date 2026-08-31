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

  /// 카테고리 + 상품 + 옵션그룹을 중첩 구조로 조회한다.
  ///
  /// [shopCategories] 와 달리 옵션이 매장 전역 평면 목록이 아니라 상품별
  /// `optionGroups[]` 안에 실려 오며, 그룹의 POS 코드(`optionGroupPosId`)가
  /// 함께 온다. 대신 **같은 옵션이 상품×그룹마다 반복 등장**하므로 옵션을
  /// 평면 목록으로 쓰려는 소비자는 `optionId` 기준 중복 제거가 필요하다
  /// (실측: 원본 4540건 → 고유 148건).
  static String shopCategoryItems(String storeId) =>
      '${shopCategories(storeId)}/items';

  static String shopItemStatus(String storeId) =>
      '$version/shops/$storeId/items/status';
  static String shopOptionStatus(String storeId) =>
      '$version/shops/$storeId/options/status';

  // Order
  // 접수/픽업요청/완료 액션. v1 미제공이라 v0 유지.
  static String orderUpdate(String orderId) => '$version/order/$orderId';

  /// 픽업 준비가 끝난(READY) 주문의 고객에게 재요청 알림을 발송한다.
  ///
  /// **주문 상태를 바꾸지 않는다** — [orderUpdate] 계열과 달리 성공해도 주문은
  /// READY 로 남는다. 알림 발송만 하는 사이드 액션이라, 호출부는 화면에서 주문이
  /// 사라지는 것을 성공 신호로 삼을 수 없다. READY 가 아니면 409.
  ///
  /// POST, body 는 `{message?}` (200자 제한, 생략하면 서버 기본 문구).
  /// v1 미제공이라 v0 유지.
  static String orderPickupNoti(String orderId) =>
      '$version/order/$orderId/pickup-noti';

  // 아래 3개만 v1. 목록/취소는 응답 스키마가 v0 과 동일하고, 상세만
  // OrderDetailV1Response 로 달라진다(옵션에 optionGroupPosId 가 실려 라벨
  // sub-info 분류의 정본이 된다).
  static const String orders = '$versionV1/orders';
  static String orderDetail(String orderId) => '$versionV1/orders/$orderId';
  static String orderCancel(String orderId) =>
      '$versionV1/order/$orderId/cancel';

  // 일괄 완료 처리는 v1 미제공이라 v0 유지.
  //
  // 아래 두 경로는 **요청 DTO 가 다르다**. 서버는 모르는 필드를 에러 없이 버리므로
  // 잘못 고른 경로가 400 으로 드러나지 않는다 — 조용히 엉뚱한 대상을 완료시킨다.
  //   bulkOrdersDone      : {shopCode, from, to}  기간 단위, READY → DONE
  //   forceBulkOrdersDone : {shopCode, orderNos[]} 주문번호 지정, PREPARING/READY → DONE
  // 특히 forceBulkOrdersDone 에 orderNos 를 빠뜨리면 400 이지만, bulkOrdersDone 에
  // orderNos 를 보내면 무시된 채 **기간 전체**가 완료된다.
  static const String bulkOrdersDone = '$version/orders/bulk-done';

  /// 주문번호를 지정해 선행 상태 검증 없이 완료까지 강제 이행한다.
  ///
  /// PREPARING 주문이 픽업 요청을 거치지 않고 바로 DONE 이 된다. 단건도 이 경로로
  /// `orderNos` 원소 1개를 보낸다(최대 100건, 중복은 1건으로 처리). 부분 실패해도
  /// 200 이므로 성공 판정은 응답의 `results[].success` 로 한다.
  static const String forceBulkOrdersDone = '$version/orders/force/bulk-done';

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
