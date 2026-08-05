import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:appfit_core/src/device/device_probe.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// [FleetIdentity.idSource] 값 상수. 기존 와이어값(order_agent 정본)과 동일하게
/// 유지한다 — 값을 바꾸면 서버·대시보드가 이미 축적한 idSource 통계가 갈라진다.
class FleetIdSources {
  FleetIdSources._();

  static const String serial = 'serial';
  static const String deviceId = 'deviceId';
  static const String installId = 'installId';
  static const String custom = 'custom';
}

/// 기기 명령 타겟팅용 안정 식별자.
class FleetIdentity {
  final String deviceId;

  /// [deviceId] 의 출처. [FleetIdSources] 값 중 하나.
  final String idSource;
  final String? serial;

  const FleetIdentity({
    required this.deviceId,
    required this.idSource,
    this.serial,
  });

  @override
  String toString() => 'FleetIdentity($deviceId, source=$idSource)';
}

/// [FleetIdentity] 조달기.
///
/// **정본은 항상 하나여야 한다.** [FleetKit] 은 앱이 이 인터페이스를 직접
/// 주입하면 core 기본 구현([DefaultFleetIdentityResolver])을 아예 만들지
/// 않는다 — "둘 다 있으면 core 가 폴백" 같은 계층형 구조는 정본이 갈라지는
/// 시나리오 그 자체라서 만들지 않는다.
abstract class FleetIdentityResolver {
  Future<FleetIdentity> resolve();

  /// 인메모리 캐시만 비운다. 영속된 serial/installId 는 절대 지우지 않는다 —
  /// 지우면 다음 조회에서 idSource 가 바뀌어 D1 에 유령 기기 행이 생긴다.
  void invalidate();
}

/// 앱의 기존 로컬 저장소 래퍼를 꽂는 2메서드 seam.
abstract class FleetIdentityStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// [SharedPreferences] 기반 기본 구현. 키는 다른 소비 앱의 저장 값과
/// 충돌하지 않도록 네임스페이스를 둔다.
class PrefsFleetIdentityStore implements FleetIdentityStore {
  static const String keyInstallId = 'appfit_core.fleet.install_id';
  static const String keySerial = 'appfit_core.fleet.serial';

  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }
}

/// 네이티브 기기 시리얼 조회. 앱이 제공(예: Android MethodChannel).
/// 미주입이거나 실패 시 null.
typedef FleetNativeSerialReader = Future<String?> Function();

/// 기본 식별자 해석기. 우선순위: 시리얼(캐시 우선, 없으면 [nativeSerial] 1회
/// 조회 후 영속) > Windows MachineGuid > 설치 UUID(생성 후 영속).
///
/// ⚠️ 시리얼은 반드시 영속 캐시해야 한다. 캐시가 없으면 부팅 시 네이티브 호출
/// 1회 실패만으로 그 부팅이 installId 로 떨어지고, 이후 시리얼을 되찾아도
/// D1 은 `(app_type, device_id)` 를 PK 로 쓰므로 이미 만들어진 행은 영구
/// 유령으로 남는다. 이 클래스가 그 캐시를 구조로 강제한다.
class DefaultFleetIdentityResolver implements FleetIdentityResolver {
  final AppFitDeviceProbe _probe;
  final FleetIdentityStore _store;
  final FleetNativeSerialReader? _nativeSerial;
  final AppFitLogger? _logger;
  final Random _random;

  FleetIdentity? _cached;

  DefaultFleetIdentityResolver({
    required AppFitDeviceProbe probe,
    FleetIdentityStore? store,
    FleetNativeSerialReader? nativeSerial,
    AppFitLogger? logger,
    Random? random,
  })  : _probe = probe,
        _store = store ?? PrefsFleetIdentityStore(),
        _nativeSerial = nativeSerial,
        _logger = logger,
        _random = random ?? Random.secure();

  @override
  Future<FleetIdentity> resolve() async {
    final cached = _cached;
    if (cached != null) return cached;

    String? serial;
    String? candidate;
    String source = FleetIdSources.installId;
    final nativeSerial = _nativeSerial;

    // 1) 하드웨어 시리얼 — 캐시 우선, 없으면 네이티브 1회 조회 후 영속.
    final cachedSerial = await _store.read(PrefsFleetIdentityStore.keySerial);
    if (cachedSerial != null && cachedSerial.isNotEmpty) {
      serial = cachedSerial;
      candidate = cachedSerial;
      source = FleetIdSources.serial;
    } else if (nativeSerial != null) {
      try {
        final s = await nativeSerial();
        if (s != null && s.isNotEmpty) {
          await _store.write(PrefsFleetIdentityStore.keySerial, s);
          serial = s;
          candidate = s;
          source = FleetIdSources.serial;
        }
      } catch (e) {
        _logger?.warn('[FleetIdentity] 네이티브 시리얼 조회 실패: $e');
      }
    }

    // 2) Windows MachineGuid.
    if (candidate == null) {
      final device = await _probe.read();
      final guid = device.windowsMachineGuid;
      if (guid != null && guid.isNotEmpty) {
        candidate = guid;
        source = FleetIdSources.deviceId;
      }
    }

    // 3) fallback: 설치 UUID(생성 후 영속).
    final String deviceId;
    if (candidate != null && candidate.isNotEmpty) {
      deviceId = candidate;
    } else {
      final existing = await _store.read(PrefsFleetIdentityStore.keyInstallId);
      if (existing != null && existing.isNotEmpty) {
        deviceId = existing;
      } else {
        final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
        final generated =
            bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        await _store.write(PrefsFleetIdentityStore.keyInstallId, generated);
        deviceId = generated;
      }
      source = FleetIdSources.installId;
    }

    final result =
        FleetIdentity(deviceId: deviceId, idSource: source, serial: serial);
    _cached = result;
    return result;
  }

  @override
  void invalidate() => _cached = null;
}
