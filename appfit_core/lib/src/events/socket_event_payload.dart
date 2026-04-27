import 'order_event_types.dart';

/// 소켓 이벤트 페이로드 값 객체
///
/// 서버-클라이언트 계약(payload 필드명)을 한 곳에서 관리합니다.
/// agent/did 양쪽에서 동일한 파싱 로직을 중복 구현하지 않도록 캡슐화합니다.
class SocketEventPayload {
  /// 파싱된 이벤트 타입 (알 수 없는 값이면 null)
  final OrderEventType? eventType;

  /// 원본 이벤트 타입 문자열
  final String? eventTypeRaw;

  /// 주문 ID (orderNo 우선, 없으면 orderId)
  final String? orderId;

  /// 매장 주문 번호 (shopOrderNo)
  final String? shopOrderNo;

  /// 고객 표시 번호 (displayOrderNo)
  final String? displayOrderNo;

  /// 매장 코드
  final String? shopCode;

  /// 원본 payload (추가 필드 접근 시 사용)
  final Map<String, dynamic> rawPayload;

  const SocketEventPayload({
    required this.eventType,
    required this.eventTypeRaw,
    required this.orderId,
    required this.shopOrderNo,
    this.displayOrderNo,
    required this.shopCode,
    required this.rawPayload,
  });

  /// 소켓 메시지 전체(data)에서 파싱
  ///
  /// data 형태: `{ "eventType": "ORDER_CREATED", "payload": { ... } }`
  factory SocketEventPayload.fromSocketMessage(Map<String, dynamic> data) {
    final eventTypeStr = data['eventType'] as String?;
    final payload = data['payload'] as Map<String, dynamic>? ?? {};

    // orderNo 우선, 없으면 orderId
    String? orderId = payload['orderNo']?.toString();
    if (orderId == null || orderId.isEmpty) {
      orderId = payload['orderId']?.toString();
    }
    if (orderId != null && orderId.isEmpty) {
      orderId = null;
    }

    return SocketEventPayload(
      eventType: eventTypeStr != null
          ? OrderEventTypeExtension.fromValue(eventTypeStr)
          : null,
      eventTypeRaw: eventTypeStr,
      orderId: orderId,
      shopOrderNo: payload['shopOrderNo']?.toString(),
      displayOrderNo: payload['displayOrderNo']?.toString(),
      shopCode: payload['shopCode']?.toString(),
      rawPayload: payload,
    );
  }

  /// orderId가 유효한지
  bool get hasOrderId => orderId != null && orderId!.isNotEmpty;

  /// 화면 표시용 번호 (displayOrderNo 우선, 그 다음 shopOrderNo, 없으면 orderId)
  /// 숫자인 경우 [padWidth] 자릿수로 패딩합니다 (기본 4자리).
  String displayNumber({int padWidth = 4}) {
    final candidates = [displayOrderNo, shopOrderNo, orderId];
    final raw = candidates.firstWhere(
      (v) => v != null && v.isNotEmpty,
      orElse: () => '',
    ) ?? '';
    final asInt = int.tryParse(raw);
    return asInt != null ? raw.padLeft(padWidth, '0') : raw;
  }

  /// 일부 필드를 교체한 새 인스턴스 반환.
  ///
  /// `rawPayload` 는 Map 이므로 깊은 복사 없이 동일 참조가 사용됩니다.
  SocketEventPayload copyWith({
    OrderEventType? eventType,
    String? eventTypeRaw,
    String? orderId,
    String? shopOrderNo,
    String? displayOrderNo,
    String? shopCode,
    Map<String, dynamic>? rawPayload,
  }) {
    return SocketEventPayload(
      eventType: eventType ?? this.eventType,
      eventTypeRaw: eventTypeRaw ?? this.eventTypeRaw,
      orderId: orderId ?? this.orderId,
      shopOrderNo: shopOrderNo ?? this.shopOrderNo,
      displayOrderNo: displayOrderNo ?? this.displayOrderNo,
      shopCode: shopCode ?? this.shopCode,
      rawPayload: rawPayload ?? this.rawPayload,
    );
  }

  /// 동등성 비교는 식별 필드만 사용합니다.
  ///
  /// `rawPayload` 는 `Map<String, dynamic>` 으로 deep equality 비교가 의미 있게
  /// 동작하지 않으므로 ==/hashCode 에서 제외했습니다. 같은 이벤트 식별 필드를
  /// 가진 두 페이로드는 동등하게 간주됩니다.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SocketEventPayload &&
        other.eventType == eventType &&
        other.eventTypeRaw == eventTypeRaw &&
        other.orderId == orderId &&
        other.shopOrderNo == shopOrderNo &&
        other.displayOrderNo == displayOrderNo &&
        other.shopCode == shopCode;
  }

  @override
  int get hashCode => Object.hash(
        eventType,
        eventTypeRaw,
        orderId,
        shopOrderNo,
        displayOrderNo,
        shopCode,
      );

  @override
  String toString() =>
      'SocketEventPayload(event=$eventTypeRaw, orderId=$orderId, shopOrderNo=$shopOrderNo, displayOrderNo=$displayOrderNo, shopCode=$shopCode)';
}