/// 주문 소켓 이벤트 타입 정의
///
/// appfit 서버-클라이언트 계약 (server contract)
enum OrderEventType {
  orderCreated,
  orderAccepted,
  orderRejected,
  orderDone,
  orderCancelled,
  orderPickupRequested,
}

extension OrderEventTypeExtension on OrderEventType {
  /// 서버에서 전송하는 실제 문자열 값
  String get value {
    switch (this) {
      case OrderEventType.orderCreated:
        return 'ORDER_CREATED';
      case OrderEventType.orderAccepted:
        return 'ORDER_ACCEPTED';
      case OrderEventType.orderRejected:
        return 'ORDER_REJECTED';
      case OrderEventType.orderDone:
        return 'ORDER_DONE';
      case OrderEventType.orderCancelled:
        return 'ORDER_CANCELLED';
      case OrderEventType.orderPickupRequested:
        return 'ORDER_PICKUP_REQUESTED';
    }
  }

  /// 서버 값으로부터 enum 찾기
  static OrderEventType? fromValue(String value) {
    for (final type in OrderEventType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}
