import '../events/order_event_types.dart';
import '../events/socket_event_payload.dart';

/// AppFit 소켓 raw 메시지를 표준화된 처리 가능 이벤트로 전처리하는 베이스 헬퍼.
///
/// 양 앱(appfit_order_agent / DID)이 공통적으로 수행하던 절차를 한 곳에 응축:
///   1. raw `Map<String, dynamic>` 을 [SocketEventPayload]로 파싱
///   2. eventType / payload / orderId 유효성 검증
///   3. 매장 코드(shopCode) 일치 여부 확인
///   4. 호출자 지정 ignore 정책 적용
///
/// 호출자는 [classify]를 호출하여 [SocketDispatchOutcome]을 받는다.
/// `accepted` 면 호출자가 페이로드를 받아 도메인별 후속 처리(상세 조회,
/// state 업데이트, 출력 등)를 진행한다. 각 앱의 후속 처리는 도메인 책임이
/// 다르므로 베이스 클래스에 흡수하지 않는다.
class SocketEventDispatcher {
  /// 매장 코드 검증용. null 이면 검증을 건너뛴다.
  final String? Function() resolveStoreId;

  /// 추가 ignore 규칙. true 를 반환하면 [SocketDispatchOutcome.ignoredByPolicy]로 분류.
  /// 호출자는 KDS NEW 차단·디스플레이 전용 등 도메인 정책을 여기서 주입한다.
  final bool Function(OrderEventType type, SocketEventPayload payload)?
      shouldIgnore;

  SocketEventDispatcher({
    required this.resolveStoreId,
    this.shouldIgnore,
  });

  /// raw 소켓 데이터를 분류하여 결과를 반환한다.
  /// 호출자는 outcome.kind 로 분기하고, accepted 인 경우 outcome.payload 를 사용한다.
  SocketDispatchOutcome classify(Map<String, dynamic> data) {
    final SocketEventPayload payload;
    try {
      payload = SocketEventPayload.fromSocketMessage(data);
    } catch (e) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.invalidPayload,
        payload: null,
        reason: 'parse error: $e',
      );
    }

    if (payload.eventTypeRaw == null) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.invalidPayload,
        payload: payload,
        reason: 'missing eventType',
      );
    }

    if (payload.eventType == null) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.unknownEventType,
        payload: payload,
        reason: 'unknown eventType=${payload.eventTypeRaw}',
      );
    }

    if (payload.rawPayload.isEmpty) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.invalidPayload,
        payload: payload,
        reason: 'empty payload',
      );
    }

    if (!payload.hasOrderId) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.invalidPayload,
        payload: payload,
        reason: 'missing orderId',
      );
    }

    // 매장 코드 일치 확인. payload 에 shopCode 가 있고 우리 매장과 다르면 무시.
    final storeId = resolveStoreId();
    final eventShopCode = payload.shopCode;
    if (eventShopCode != null &&
        storeId != null &&
        eventShopCode.toUpperCase() != storeId.toUpperCase()) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.ignoredByShopCode,
        payload: payload,
        reason: 'shopCode mismatch (expected=$storeId, got=$eventShopCode)',
      );
    }

    if (shouldIgnore != null && shouldIgnore!(payload.eventType!, payload)) {
      return SocketDispatchOutcome._(
        kind: SocketDispatchKind.ignoredByPolicy,
        payload: payload,
        reason: 'ignored by policy',
      );
    }

    return SocketDispatchOutcome._(
      kind: SocketDispatchKind.accepted,
      payload: payload,
      reason: null,
    );
  }
}

/// 분류 결과 종류.
enum SocketDispatchKind {
  /// 파싱 가능하고 정책 통과. 호출자가 처리 가능.
  accepted,

  /// 페이로드 자체가 유효하지 않음(파싱 실패, 필드 누락 등).
  invalidPayload,

  /// 알려지지 않은 이벤트 타입(서버 신규 추가분 등).
  unknownEventType,

  /// 다른 매장 이벤트.
  ignoredByShopCode,

  /// 도메인 정책에 의해 무시(KDS NEW, 디스플레이 전용 CREATED/REJECTED 등).
  ignoredByPolicy,
}

/// 분류 결과 값 객체.
class SocketDispatchOutcome {
  final SocketDispatchKind kind;
  final SocketEventPayload? payload;
  final String? reason;

  const SocketDispatchOutcome._({
    required this.kind,
    required this.payload,
    required this.reason,
  });

  bool get isAccepted => kind == SocketDispatchKind.accepted;

  @override
  String toString() =>
      'SocketDispatchOutcome(kind=$kind, reason=$reason, payload=$payload)';
}
