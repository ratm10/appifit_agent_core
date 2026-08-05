import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

class _FakeProbe implements AppFitDeviceProbe {
  _FakeProbe(this._info);
  final AppFitDeviceInfo _info;
  bool shouldThrow = false;

  @override
  Future<AppFitDeviceInfo> read() async {
    if (shouldThrow) throw Exception('probe boom');
    return _info;
  }
}

class _FakeIdentity implements FleetIdentityResolver {
  _FakeIdentity(this._identity);
  final FleetIdentity _identity;
  bool shouldThrow = false;

  @override
  Future<FleetIdentity> resolve() async {
    if (shouldThrow) throw Exception('identity boom');
    return _identity;
  }

  @override
  void invalidate() {}
}

class _CapturingLogger implements AppFitLogger {
  final List<String> logs = [];

  @override
  Future<void> log(String message) async => logs.add(message);

  @override
  Future<void> error(String message, dynamic error) async =>
      logs.add('$message: $error');
}

const _deviceInfo = AppFitDeviceInfo(
  platform: 'android',
  osVersion: '13',
  deviceModel: 'SUNMI D3 MINI',
  deviceManufacturer: 'SUNMI',
  appVersion: '3.2.1',
  buildNumber: '412',
);

const _identity = FleetIdentity(
  deviceId: 'DE33256H10784',
  idSource: FleetIdSources.serial,
  serial: 'DE33256H10784',
);

void main() {
  test('readAppState 의 storeId/storeName/mode/businessOpen 이 그대로 전달된다',
      () async {
    final assembler = FleetSnapshotAssembler(
      appType: 'DID',
      readAppState: () => const FleetAppState(
        storeId: 'MATA00001',
        storeName: '마타 강남점',
        mode: 'SIGNAGE',
        businessOpen: true,
      ),
      identity: _FakeIdentity(_identity),
      probe: _FakeProbe(_deviceInfo),
      readConnection: () async => 'wifi',
    );

    final snapshot = await assembler.build();

    expect(snapshot, isNotNull);
    expect(snapshot!.device.appType, 'DID');
    expect(snapshot.device.storeId, 'MATA00001');
    expect(snapshot.device.storeName, '마타 강남점');
    expect(snapshot.runtime.mode, 'SIGNAGE');
    expect(snapshot.runtime.businessOpen, isTrue);
    expect(snapshot.runtime.connection, 'wifi');
  });

  test('probe 실패 시 스냅샷은 null 이고 예외가 전파되지 않는다', () async {
    final probe = _FakeProbe(_deviceInfo)..shouldThrow = true;
    final assembler = FleetSnapshotAssembler(
      appType: 'DID',
      readAppState: () => const FleetAppState(),
      identity: _FakeIdentity(_identity),
      probe: probe,
      readConnection: () async => null,
    );

    expect(await assembler.build(), isNull);
  });

  test('identity 실패 시에도 스냅샷은 null 이다', () async {
    final identity = _FakeIdentity(_identity)..shouldThrow = true;
    final assembler = FleetSnapshotAssembler(
      appType: 'DID',
      readAppState: () => const FleetAppState(),
      identity: identity,
      probe: _FakeProbe(_deviceInfo),
      readConnection: () async => null,
    );

    expect(await assembler.build(), isNull);
  });

  test('commandRunningProbe 가 결선되면 결과가 반영된다', () async {
    final assembler = FleetSnapshotAssembler(
      appType: 'DID',
      readAppState: () => const FleetAppState(),
      identity: _FakeIdentity(_identity),
      probe: _FakeProbe(_deviceInfo),
      readConnection: () async => null,
    )..commandRunningProbe = () => true;

    final snapshot = await assembler.build();
    expect(snapshot!.runtime.commandRunning, isTrue);
  });

  group('extra 정제', () {
    test('스칼라 값은 그대로 통과한다', () async {
      final assembler = FleetSnapshotAssembler(
        appType: 'DID',
        readAppState: () => const FleetAppState(extra: {
          'restartReason': 'preventive',
          'temp': 42,
          'ok': true,
          'nothing': null,
        }),
        identity: _FakeIdentity(_identity),
        probe: _FakeProbe(_deviceInfo),
        readConnection: () async => null,
      );

      final snapshot = await assembler.build();
      expect(snapshot!.runtime.extra, {
        'restartReason': 'preventive',
        'temp': 42,
        'ok': true,
        'nothing': null,
      });
    });

    test('비스칼라 값은 제외되고 경고 로그를 남긴다', () async {
      final logger = _CapturingLogger();
      final assembler = FleetSnapshotAssembler(
        appType: 'DID',
        readAppState: () => const FleetAppState(extra: {
          'ok': 'fine',
          'bad': <String, String>{'x': 'y'},
        }),
        identity: _FakeIdentity(_identity),
        probe: _FakeProbe(_deviceInfo),
        readConnection: () async => null,
        logger: logger,
      );

      final snapshot = await assembler.build();
      expect(snapshot!.runtime.extra, {'ok': 'fine'});
      expect(
        logger.logs.any((l) => l.contains('[WARN]') && l.contains('bad')),
        isTrue,
      );
    });

    test('직렬화 크기가 상한을 넘으면 통째로 버려진다', () async {
      final logger = _CapturingLogger();
      final huge = 'x' * (FleetRuntime.extraMaxBytes + 100);
      final assembler = FleetSnapshotAssembler(
        appType: 'DID',
        readAppState: () => FleetAppState(extra: {'blob': huge}),
        identity: _FakeIdentity(_identity),
        probe: _FakeProbe(_deviceInfo),
        readConnection: () async => null,
        logger: logger,
      );

      final snapshot = await assembler.build();
      expect(snapshot!.runtime.extra, isEmpty);
      expect(
        logger.logs.any((l) => l.contains('[WARN]') && l.contains('크기 초과')),
        isTrue,
      );
    });

    test('extra 가 device.fingerprint 에 영향을 주지 않는다 (boot_count 오염 회귀)',
        () async {
      final withExtra = FleetSnapshotAssembler(
        appType: 'DID',
        readAppState: () =>
            const FleetAppState(storeId: 'MATA00001', extra: {'a': 1}),
        identity: _FakeIdentity(_identity),
        probe: _FakeProbe(_deviceInfo),
        readConnection: () async => null,
      );
      final withoutExtra = FleetSnapshotAssembler(
        appType: 'DID',
        readAppState: () => const FleetAppState(storeId: 'MATA00001'),
        identity: _FakeIdentity(_identity),
        probe: _FakeProbe(_deviceInfo),
        readConnection: () async => null,
      );

      final a = await withExtra.build();
      final b = await withoutExtra.build();
      expect(a!.device.fingerprint, b!.device.fingerprint);
    });
  });
}
