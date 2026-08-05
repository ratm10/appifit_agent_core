import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

class _FakeStore implements FleetIdentityStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;
}

class _FakeProbe implements AppFitDeviceProbe {
  _FakeProbe({this.windowsMachineGuid});
  final String? windowsMachineGuid;

  @override
  Future<AppFitDeviceInfo> read() async => AppFitDeviceInfo(
        platform: 'windows',
        osVersion: '22H2',
        deviceModel: 'POS-01',
        deviceManufacturer: 'Microsoft',
        appVersion: '1.0.0',
        buildNumber: '1',
        windowsMachineGuid: windowsMachineGuid,
      );
}

void main() {
  test('첫 네이티브 시리얼 성공 시 영속되고 idSource=serial', () async {
    final store = _FakeStore();
    final resolver = DefaultFleetIdentityResolver(
      probe: _FakeProbe(),
      store: store,
      nativeSerial: () async => 'SN-001',
    );

    final identity = await resolver.resolve();

    expect(identity.idSource, FleetIdSources.serial);
    expect(identity.deviceId, 'SN-001');
    expect(await store.read(PrefsFleetIdentityStore.keySerial), 'SN-001');
  });

  test('2회차 부팅에서 네이티브 호출이 실패해도 idSource 가 installId 로 뒤집히지 않는다', () async {
    final store = _FakeStore();

    // 1차 부팅: 네이티브 성공, 시리얼 영속.
    final firstBoot = DefaultFleetIdentityResolver(
      probe: _FakeProbe(),
      store: store,
      nativeSerial: () async => 'SN-002',
    );
    final first = await firstBoot.resolve();
    expect(first.idSource, FleetIdSources.serial);

    // 2차 부팅: 새 resolver 인스턴스(콜드 스타트 재현), 네이티브 호출은 실패.
    final secondBoot = DefaultFleetIdentityResolver(
      probe: _FakeProbe(),
      store: store,
      nativeSerial: () async => throw Exception('native channel down'),
    );
    final second = await secondBoot.resolve();

    expect(
      second.idSource,
      FleetIdSources.serial,
      reason: '캐시된 시리얼이 있으면 네이티브를 다시 부르지 않는다 — 유령 기기 회귀',
    );
    expect(second.deviceId, first.deviceId);
  });

  test('Windows MachineGuid 를 idSource=deviceId 로 사용한다', () async {
    final resolver = DefaultFleetIdentityResolver(
      probe: _FakeProbe(windowsMachineGuid: 'GUID-XYZ'),
      store: _FakeStore(),
    );

    final identity = await resolver.resolve();

    expect(identity.idSource, FleetIdSources.deviceId);
    expect(identity.deviceId, 'GUID-XYZ');
  });

  test('시리얼/GUID 모두 없으면 설치 UUID 를 생성하고 영속한다', () async {
    final store = _FakeStore();

    final resolver1 = DefaultFleetIdentityResolver(
      probe: _FakeProbe(),
      store: store,
    );
    final id1 = await resolver1.resolve();
    expect(id1.idSource, FleetIdSources.installId);

    // 재부팅(새 resolver 인스턴스)에도 같은 UUID 를 재사용해야 한다.
    final resolver2 = DefaultFleetIdentityResolver(
      probe: _FakeProbe(),
      store: store,
    );
    final id2 = await resolver2.resolve();
    expect(id2.deviceId, id1.deviceId);
  });

  test('invalidate() 는 인메모리 캐시만 비우고 deviceId 는 불변이다', () async {
    final store = _FakeStore();
    final resolver = DefaultFleetIdentityResolver(
      probe: _FakeProbe(),
      store: store,
      nativeSerial: () async => 'SN-003',
    );

    final before = await resolver.resolve();
    resolver.invalidate();
    final after = await resolver.resolve();

    expect(after.deviceId, before.deviceId);
    expect(after.idSource, FleetIdSources.serial);
  });
}
