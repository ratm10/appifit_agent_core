/// 인증 상태 제공자 인터페이스.
///
/// 프로젝트별로 현재 로그인된 storeId와 세션 비밀번호를 제공해야 합니다.
/// `AppFitDioProvider` 에 선택적으로 주입되어 요청 인터셉터가 shopCode /
/// password 를 확보할 때 최종 폴백으로 사용됩니다.
abstract class AuthStateProvider {
  /// 현재 로그인된 매장(shop) 식별자. 비로그인 상태면 null.
  String? get currentStoreId;

  /// 현재 세션 비밀번호. 토큰 재발급이 필요할 때 사용됩니다. 비로그인 상태면 null.
  String? get currentPassword;
}
