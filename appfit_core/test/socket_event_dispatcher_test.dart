import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SocketEventDispatcher', () {
    Map<String, dynamic> validData({
      String eventType = 'ORDER_ACCEPTED',
      String? orderId = 'O-100',
      String? shopCode,
      Map<String, dynamic>? extra,
    }) {
      final payload = <String, dynamic>{
        if (orderId != null) 'orderId': orderId,
        if (shopCode != null) 'shopCode': shopCode,
        ...?extra,
      };
      return <String, dynamic>{
        'eventType': eventType,
        'payload': payload,
      };
    }

    test('정상 페이로드는 accepted 로 분류된다', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => 'STORE_A',
      );
      final outcome = dispatcher.classify(
        validData(shopCode: 'STORE_A'),
      );
      expect(outcome.kind, SocketDispatchKind.accepted);
      expect(outcome.isAccepted, true);
      expect(outcome.payload?.orderId, 'O-100');
      expect(outcome.payload?.eventType, OrderEventType.orderAccepted);
    });

    test('eventType 누락은 invalidPayload 로 분류된다', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
      );
      final outcome = dispatcher.classify(<String, dynamic>{
        'payload': {'orderId': 'X'},
      });
      expect(outcome.kind, SocketDispatchKind.invalidPayload);
    });

    test('알 수 없는 eventType 은 unknownEventType 로 분류된다', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
      );
      final outcome = dispatcher.classify(<String, dynamic>{
        'eventType': 'ORDER_FOO_BAR',
        'payload': {'orderId': 'X'},
      });
      expect(outcome.kind, SocketDispatchKind.unknownEventType);
    });

    test('빈 payload 는 invalidPayload', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
      );
      final outcome = dispatcher.classify(<String, dynamic>{
        'eventType': 'ORDER_ACCEPTED',
        'payload': <String, dynamic>{},
      });
      expect(outcome.kind, SocketDispatchKind.invalidPayload);
    });

    test('orderId 누락은 invalidPayload', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
      );
      final outcome = dispatcher.classify(
        validData(orderId: null, extra: {'shopOrderNo': '1'}),
      );
      expect(outcome.kind, SocketDispatchKind.invalidPayload);
    });

    test('shopCode 불일치는 ignoredByShopCode', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => 'STORE_A',
      );
      final outcome = dispatcher.classify(
        validData(shopCode: 'STORE_B'),
      );
      expect(outcome.kind, SocketDispatchKind.ignoredByShopCode);
    });

    test('shopCode 대소문자 무시 일치는 통과', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => 'store_a',
      );
      final outcome = dispatcher.classify(
        validData(shopCode: 'STORE_A'),
      );
      expect(outcome.kind, SocketDispatchKind.accepted);
    });

    test('storeId 가 null 이면 shopCode 검증을 건너뛴다', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
      );
      final outcome = dispatcher.classify(
        validData(shopCode: 'STORE_X'),
      );
      expect(outcome.kind, SocketDispatchKind.accepted);
    });

    test('shouldIgnore 콜백 true 는 ignoredByPolicy', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
        shouldIgnore: (type, _) =>
            OrderEventIgnorePolicy.ignoreForDisplayOnly(type),
      );
      final outcome = dispatcher.classify(
        validData(eventType: 'ORDER_CREATED'),
      );
      expect(outcome.kind, SocketDispatchKind.ignoredByPolicy);
    });

    test('shouldIgnore 콜백 false 는 accepted', () {
      final dispatcher = SocketEventDispatcher(
        resolveStoreId: () => null,
        shouldIgnore: (type, _) =>
            OrderEventIgnorePolicy.ignoreForDisplayOnly(type),
      );
      final outcome = dispatcher.classify(
        validData(eventType: 'ORDER_ACCEPTED'),
      );
      expect(outcome.kind, SocketDispatchKind.accepted);
    });
  });
}
