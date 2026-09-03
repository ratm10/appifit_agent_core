import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

class _FakeStore implements FleetIdentityStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;
}

void main() {
  test('첫 네이티브 시리얼 성공 시 영속되고 idSource=serial', () async {
    final store = _FakeStore();
    final resolver = DefaultFleetIdentityResolver(
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
      store: store,
      nativeSerial: () async => 'SN-002',
    );
    final first = await firstBoot.resolve();
    expect(first.idSource, FleetIdSources.serial);

    // 2차 부팅: 새 resolver 인스턴스(콜드 스타트 재현), 네이티브 호출은 실패.
    final secondBoot = DefaultFleetIdentityResolver(
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

  test('클론 이미지로 배포된 두 Windows PC 는 서로 다른 deviceId 를 갖는다', () async {
    // 회귀 방지. 예전에는 Windows MachineGuid 를 식별자로 썼는데, 그 값은
    // sysprep 없이 복제 배포된 PC 들에서 전부 같아 서로 다른 매장의 두 기기가
    // D1 의 기기 행 하나를 번갈아 덮어썼다. 이제 resolver 가 기기 정보를 아예
    // 읽지 않으므로 두 설치는 각자의 설치 UUID 로 반드시 갈라져야 한다.
    final a = await DefaultFleetIdentityResolver(store: _FakeStore()).resolve();
    final b = await DefaultFleetIdentityResolver(store: _FakeStore()).resolve();

    expect(a.idSource, FleetIdSources.installId);
    expect(b.idSource, FleetIdSources.installId);
    expect(a.deviceId, isNot(b.deviceId));
  });

  test('시리얼이 없으면 설치 UUID 를 생성하고 영속한다', () async {
    final store = _FakeStore();

    final resolver1 = DefaultFleetIdentityResolver(store: store);
    final id1 = await resolver1.resolve();
    expect(id1.idSource, FleetIdSources.installId);

    // 재부팅(새 resolver 인스턴스)에도 같은 UUID 를 재사용해야 한다.
    final resolver2 = DefaultFleetIdentityResolver(store: store);
    final id2 = await resolver2.resolve();
    expect(id2.deviceId, id1.deviceId);
  });

  test('invalidate() 는 인메모리 캐시만 비우고 deviceId 는 불변이다', () async {
    final store = _FakeStore();
    final resolver = DefaultFleetIdentityResolver(
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
