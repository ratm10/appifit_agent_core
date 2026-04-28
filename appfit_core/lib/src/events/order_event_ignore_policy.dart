import 'order_event_types.dart';

/// 주문 이벤트를 어느 시점에 무시할지 결정하는 정책 모음.
///
/// 각 앱이 인라인으로 분산해 갖던 분기를 한 곳에 응축하여, 정책 변경 시
/// 단일 진입점만 수정하면 양 앱이 동시에 따라가도록 한다.
///
/// - [ignoreNewOrderInKdsMode]: appfit_order_agent KDS 모드는 NEW 주문
///   처리(소켓 ORDER_CREATED + 폴링 NEW 응답)를 모두 무시한다.
/// - [ignoreForDisplayOnly]: DID 같은 디스플레이 전용 앱은 ORDER_CREATED /
///   ORDER_REJECTED 를 무시한다(접수 처리를 하지 않으므로).
class OrderEventIgnorePolicy {
  const OrderEventIgnorePolicy._();

  /// KDS 모드에서 신규(NEW) 주문 처리를 무시할지.
  ///
  /// KDS 는 PREPARING 이후 단계만 다루므로:
  /// - 소켓 `ORDER_CREATED` 이벤트는 무시
  /// - 폴링 응답의 NEW 상태 주문은 자동접수 시도하지 않고 스킵
  ///
  /// 정책이 바뀌면(예: KDS 라우팅 도입) 이 한 곳만 수정한다.
  static bool ignoreNewOrderInKdsMode(bool isKdsMode) => isKdsMode;

  /// 디스플레이 전용 앱에서 무시해야 할 이벤트 타입인지.
  ///
  /// DID 같이 주문 라이프사이클을 관리하지 않고 표시만 하는 앱은
  /// 접수 단계 이벤트(ORDER_CREATED, ORDER_REJECTED)를 무시한다.
  static bool ignoreForDisplayOnly(OrderEventType type) {
    return type == OrderEventType.orderCreated ||
        type == OrderEventType.orderRejected;
  }
}
