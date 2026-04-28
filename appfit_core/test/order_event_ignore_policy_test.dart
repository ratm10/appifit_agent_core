import 'package:appfit_core/appfit_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OrderEventIgnorePolicy', () {
    group('ignoreNewOrderInKdsMode', () {
      test('KDS 모드에서는 NEW 처리 무시', () {
        expect(
          OrderEventIgnorePolicy.ignoreNewOrderInKdsMode(true),
          true,
        );
      });

      test('일반 모드에서는 NEW 처리 진행', () {
        expect(
          OrderEventIgnorePolicy.ignoreNewOrderInKdsMode(false),
          false,
        );
      });
    });

    group('ignoreForDisplayOnly', () {
      test('ORDER_CREATED 무시', () {
        expect(
          OrderEventIgnorePolicy.ignoreForDisplayOnly(
            OrderEventType.orderCreated,
          ),
          true,
        );
      });

      test('ORDER_REJECTED 무시', () {
        expect(
          OrderEventIgnorePolicy.ignoreForDisplayOnly(
            OrderEventType.orderRejected,
          ),
          true,
        );
      });

      test('ORDER_ACCEPTED 통과', () {
        expect(
          OrderEventIgnorePolicy.ignoreForDisplayOnly(
            OrderEventType.orderAccepted,
          ),
          false,
        );
      });

      test('ORDER_PICKUP_REQUESTED 통과', () {
        expect(
          OrderEventIgnorePolicy.ignoreForDisplayOnly(
            OrderEventType.orderPickupRequested,
          ),
          false,
        );
      });

      test('ORDER_DONE 통과', () {
        expect(
          OrderEventIgnorePolicy.ignoreForDisplayOnly(
            OrderEventType.orderDone,
          ),
          false,
        );
      });

      test('ORDER_CANCELLED 통과', () {
        expect(
          OrderEventIgnorePolicy.ignoreForDisplayOnly(
            OrderEventType.orderCancelled,
          ),
          false,
        );
      });
    });
  });
}
