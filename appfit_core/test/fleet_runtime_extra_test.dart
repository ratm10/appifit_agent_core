// ignore_for_file: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

const _device = FleetDeviceInfo(
  deviceId: 'DE33256H10784',
  idSource: 'serial',
  serial: 'DE33256H10784',
  appType: 'ORDER_AGENT',
  storeId: 'MATA00001',
  storeName: '마타 강남점',
  appVersion: '3.2.1',
  buildNumber: '412',
  platform: 'android',
  osVersion: '13',
  deviceModel: 'SUNMI D3 MINI',
  deviceManufacturer: 'SUNMI',
  environment: 'live',
);

class _RecordingSink implements FleetSink {
  _RecordingSink(this.calls);
  final List<String> calls;

  @override
  String get name => 'Recording';

  @override
  bool get isConfigured => true;

  @override
  Future<FleetAck> register(FleetDeviceInfo device) async {
    calls.add('register');
    return const FleetAck(success: true);
  }

  @override
  Future<FleetAck> heartbeat(
    FleetSnapshot snapshot,
    List<FleetCommandResult> results,
  ) async {
    calls.add('heartbeat');
    return const FleetAck(success: true);
  }
}

void main() {
  group('FleetRuntime.extra', () {
    test('비어 있으면 toJson 에서 키 자체가 빠진다', () {
      const runtime = FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: true,
      );
      expect(runtime.toJson().containsKey('extra'), isFalse);
    });

    test('값이 있으면 toJson 에 그대로 포함된다', () {
      const runtime = FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: true,
        extra: {'restartReason': 'preventive', 'bootCount': 4},
      );
      expect(
        runtime.toJson()['extra'],
        {'restartReason': 'preventive', 'bootCount': 4},
      );
    });

    test('copyWith 는 extra 를 지정하지 않으면 유지한다', () {
      const runtime = FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: true,
        extra: {'a': 1},
      );
      final copy = runtime.copyWith(status: FleetStatus.closing);
      expect(copy.extra, {'a': 1});
    });

    test('copyWith 는 extra 를 지정하면 교체한다', () {
      const runtime = FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: true,
        extra: {'a': 1},
      );
      final copy = runtime.copyWith(extra: {'b': 2});
      expect(copy.extra, {'b': 2});
    });

    test('FleetDeviceInfo.fingerprint 는 runtime.extra 를 전혀 참조하지 않는다', () {
      const snapshotA = FleetSnapshot(
        device: _device,
        runtime: FleetRuntime(
          status: FleetStatus.online,
          lifecycle: 'resumed',
          socketConnected: true,
          extra: {'a': 1},
        ),
      );
      const snapshotB = FleetSnapshot(
        device: _device,
        runtime: FleetRuntime(
          status: FleetStatus.online,
          lifecycle: 'resumed',
          socketConnected: true,
          extra: {'a': 2, 'b': 'x'},
        ),
      );
      expect(snapshotA.device.fingerprint, snapshotB.device.fingerprint);
    });
  });

  group('보고 케이던스와 extra (boot_count 오염 회귀)', () {
    test('extra 만 바뀌어도 register 가 재발화하지 않는다', () {
      fakeAsync((async) {
        var tick = 0;
        final calls = <String>[];
        final reporter = FleetReporter(
          sink: _RecordingSink(calls),
          snapshotBuilder: () async {
            tick++;
            return FleetSnapshot(
              device: _device,
              runtime: FleetRuntime(
                status: FleetStatus.online,
                lifecycle: 'resumed',
                socketConnected: true,
                extra: {'tick': tick},
              ),
            );
          },
          isOnline: () async => true,
          interval: const Duration(seconds: 60),
        )..start();

        async.elapse(const Duration(milliseconds: 1));
        async.elapse(const Duration(seconds: 60));
        async.elapse(const Duration(seconds: 60));

        expect(calls, ['register', 'heartbeat', 'heartbeat']);
        reporter.stop();
      });
    });
  });
}
