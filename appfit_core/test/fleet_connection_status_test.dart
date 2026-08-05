import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

class _ScriptedSink implements FleetSink {
  _ScriptedSink(this._ack);
  final FleetAck Function() _ack;

  @override
  String get name => 'Scripted';

  @override
  bool get isConfigured => true;

  @override
  Future<FleetAck> register(FleetDeviceInfo device) async => _ack();

  @override
  Future<FleetAck> heartbeat(
    FleetSnapshot snapshot,
    List<FleetCommandResult> results,
  ) async =>
      _ack();
}

class _ThrowingSink implements FleetSink {
  @override
  String get name => 'Throwing';

  @override
  bool get isConfigured => true;

  @override
  Future<FleetAck> register(FleetDeviceInfo device) async =>
      throw Exception('boom');

  @override
  Future<FleetAck> heartbeat(
    FleetSnapshot snapshot,
    List<FleetCommandResult> results,
  ) async =>
      throw Exception('boom');
}

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

void main() {
  test('성공 ack 는 connected 를 통지한다', () async {
    final statuses = <FleetConnectionStatus>[];
    final sink = ObservingFleetSink(
      inner: _ScriptedSink(() => const FleetAck(success: true)),
      onStatus: statuses.add,
    );

    await sink.register(_device);

    expect(statuses, [FleetConnectionStatus.connected]);
  });

  test('실패 ack 는 error 를 통지한다', () async {
    final statuses = <FleetConnectionStatus>[];
    final sink = ObservingFleetSink(
      inner: _ScriptedSink(() => const FleetAck.fail('boom')),
      onStatus: statuses.add,
    );

    final ack = await sink.register(_device);

    expect(ack.success, isFalse);
    expect(statuses, [FleetConnectionStatus.error]);
  });

  test('예외가 나면 error 를 통지한 뒤 그대로 rethrow 한다', () async {
    final statuses = <FleetConnectionStatus>[];
    final sink =
        ObservingFleetSink(inner: _ThrowingSink(), onStatus: statuses.add);

    await expectLater(sink.register(_device), throwsException);
    expect(statuses, [FleetConnectionStatus.error]);
  });

  test('name/isConfigured 는 inner 에 위임한다', () {
    final inner = _ScriptedSink(() => const FleetAck(success: true));
    final sink = ObservingFleetSink(inner: inner, onStatus: (_) {});

    expect(sink.name, inner.name);
    expect(sink.isConfigured, inner.isConfigured);
  });
}
