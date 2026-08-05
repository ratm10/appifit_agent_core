// ignore_for_file: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

class _FakeSink implements FleetSink {
  final List<String> calls = [];
  final List<FleetStatus> statuses = [];

  @override
  String get name => 'Fake';

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
    statuses.add(snapshot.runtime.status);
    return const FleetAck(success: true);
  }
}

class _FakeIdentityResolver implements FleetIdentityResolver {
  @override
  Future<FleetIdentity> resolve() async =>
      const FleetIdentity(deviceId: 'X', idSource: FleetIdSources.custom);

  @override
  void invalidate() {}
}

/// 실제 device_info_plus/package_info_plus 플랫폼 채널을 타지 않도록 하는
/// 페이크. 케이던스/라이프사이클 검증은 이 값들과 무관하다.
class _FakeProbe implements AppFitDeviceProbe {
  @override
  Future<AppFitDeviceInfo> read() async => const AppFitDeviceInfo(
        platform: 'android',
        osVersion: '13',
        deviceModel: 'SUNMI D3 MINI',
        deviceManufacturer: 'SUNMI',
        appVersion: '3.2.1',
        buildNumber: '412',
      );
}

FleetAppState _appState() =>
    const FleetAppState(storeId: 'MATA00001', storeName: '마타 강남점');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sink 와 baseUrl 을 동시에 주입하면 assert 가 발화한다', () {
    expect(
      () => FleetKit(
        appType: 'TEST',
        readAppState: _appState,
        sink: _FakeSink(),
        baseUrl: 'https://example.com',
        observeLifecycle: false,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('identity 와 nativeSerial 을 동시에 주입하면 assert 가 발화한다', () {
    expect(
      () => FleetKit(
        appType: 'TEST',
        readAppState: _appState,
        sink: _FakeSink(),
        identity: _FakeIdentityResolver(),
        nativeSerial: () async => 'X',
        observeLifecycle: false,
      ),
      throwsA(isA<AssertionError>()),
    );
  });

  test('baseUrl/deviceKey 가 비면 disabled 로 시작하고 HTTP 를 시도하지 않는다', () {
    final kit = FleetKit(
      appType: 'TEST',
      readAppState: _appState,
      observeLifecycle: false,
    );

    expect(kit.isEnabled, isFalse);
    expect(kit.connectionStatus.value, FleetConnectionStatus.disabled);
    kit.dispose();
  });

  test('sink 가 설정되면 connecting 으로 시작한다', () {
    final kit = FleetKit(
      appType: 'TEST',
      readAppState: _appState,
      sink: _FakeSink(),
      observeLifecycle: false,
    );

    expect(kit.isEnabled, isTrue);
    expect(kit.connectionStatus.value, FleetConnectionStatus.connecting);
    kit.dispose();
  });

  test('start/stop 이 케이던스를 제어한다', () {
    fakeAsync((async) {
      final sink = _FakeSink();
      final kit = FleetKit(
        appType: 'TEST',
        readAppState: _appState,
        sink: sink,
        identity: _FakeIdentityResolver(),
        deviceProbe: _FakeProbe(),
        isOnline: () async => true,
        readConnection: () async => 'wifi',
        interval: const Duration(seconds: 60),
        jitterMs: 0,
        observeLifecycle: false,
      );

      kit.start();
      async.elapse(const Duration(milliseconds: 1));
      expect(sink.calls, ['register']);

      kit.stop();
      async.elapse(const Duration(seconds: 120));
      expect(sink.calls, ['register'], reason: 'stop 이후에는 추가 틱이 없어야 한다');
    });
  });

  test('onStoreChanged 는 다음 틱을 register 로 강제한다', () {
    fakeAsync((async) {
      final sink = _FakeSink();
      final kit = FleetKit(
        appType: 'TEST',
        readAppState: _appState,
        sink: sink,
        identity: _FakeIdentityResolver(),
        deviceProbe: _FakeProbe(),
        isOnline: () async => true,
        readConnection: () async => 'wifi',
        interval: const Duration(seconds: 60),
        jitterMs: 0,
        observeLifecycle: false,
      )..start();

      async.elapse(const Duration(milliseconds: 1));
      expect(sink.calls, ['register']);

      async.elapse(const Duration(seconds: 60));
      expect(sink.calls, ['register', 'heartbeat']);

      kit.onStoreChanged();
      async.elapse(const Duration(milliseconds: 1));
      expect(sink.calls.last, 'register');

      kit.stop();
    });
  });

  test('detached 에서만 closing 을 정확히 1회 보낸다 (paused 는 무시)', () {
    fakeAsync((async) {
      final sink = _FakeSink();
      final kit = FleetKit(
        appType: 'TEST',
        readAppState: _appState,
        sink: sink,
        identity: _FakeIdentityResolver(),
        deviceProbe: _FakeProbe(),
        isOnline: () async => true,
        readConnection: () async => 'wifi',
        interval: const Duration(seconds: 60),
        jitterMs: 0,
        observeLifecycle: false,
      )..start();

      async.elapse(const Duration(milliseconds: 1));

      kit.lifecycle = AppLifecycleState.paused;
      async.elapse(const Duration(milliseconds: 1));
      expect(
        sink.statuses,
        isNot(contains(FleetStatus.closing)),
        reason: 'paused 는 Android 오버레이 버블 때문에 상시 발생 — closing 을 보내면 안 된다',
      );

      kit.lifecycle = AppLifecycleState.detached;
      async.elapse(const Duration(milliseconds: 1));
      expect(sink.statuses.where((s) => s == FleetStatus.closing).length, 1);

      // 같은 세션에서 detached 가 반복돼도 closing 은 1회로 고정된다.
      kit.lifecycle = AppLifecycleState.detached;
      async.elapse(const Duration(milliseconds: 1));
      expect(sink.statuses.where((s) => s == FleetStatus.closing).length, 1);

      kit.stop();
    });
  });

  test('dispose 는 라이프사이클 옵저버를 해제한다', () {
    final kit = FleetKit(
      appType: 'TEST',
      readAppState: _appState,
      sink: _FakeSink(),
    );

    kit.dispose();

    expect(
      WidgetsBinding.instance.removeObserver(kit),
      isFalse,
      reason: 'dispose 가 이미 해제했어야 한다',
    );
  });

  test('observeLifecycle=false 면 옵저버를 등록하지 않는다', () {
    final kit = FleetKit(
      appType: 'TEST',
      readAppState: _appState,
      sink: _FakeSink(),
      observeLifecycle: false,
    );

    expect(WidgetsBinding.instance.removeObserver(kit), isFalse);
    kit.dispose();
  });
}
