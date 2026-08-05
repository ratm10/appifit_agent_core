import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:appfit_core/src/config/appfit_config.dart';
import 'package:appfit_core/src/device/device_probe.dart';
import 'package:appfit_core/src/fleet/fleet_app_state.dart';
import 'package:appfit_core/src/fleet/fleet_identity.dart';
import 'package:appfit_core/src/fleet/fleet_models.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// [FleetSnapshotBuilder] 의 범용 구현. 정적 기기정보·식별자·연결성은
/// 기계적으로 조립하고, storeId/storeName/mode/businessOpen 등 앱 고유 값만
/// [readAppState] 로 받는다.
///
/// 매 틱 호출되므로 값이 늦게 채워지는 문제(로그인 전 storeId 없음)가
/// 저절로 해결된다. 예외가 나면 null 을 돌려주고, 리포터는 실패로 세지 않는다.
class FleetSnapshotAssembler {
  final String _appType;
  final FleetAppStateReader _readAppState;
  final FleetIdentityResolver _identity;
  final AppFitDeviceProbe _probe;
  final Future<String?> Function() _readConnection;
  final String Function() _environment;
  final AppFitLogger? _logger;

  /// 소켓 연결 상태. 앱이 갱신한다.
  bool socketConnected = false;

  /// 앱 라이프사이클(resumed/paused/...). [FleetKit] 이 갱신한다.
  String lifecycle = 'resumed';

  /// 장시간 명령 진행 여부. 리포터 생성 후 배선한다(순환 참조 회피).
  bool Function()? commandRunningProbe;

  FleetSnapshotAssembler({
    required String appType,
    required FleetAppStateReader readAppState,
    required FleetIdentityResolver identity,
    required AppFitDeviceProbe probe,
    Future<String?> Function()? readConnection,
    String Function()? environment,
    AppFitLogger? logger,
  })  : _appType = appType,
        _readAppState = readAppState,
        _identity = identity,
        _probe = probe,
        _readConnection = readConnection ?? _defaultReadConnection,
        _environment = environment ?? (() => AppFitConfig.environment.name),
        _logger = logger;

  Future<FleetSnapshot?> build() async {
    try {
      final identity = await _identity.resolve();
      final device = await _probe.read();
      final appState = _readAppState();

      final extra = _sanitizeExtra(appState.extra);

      return FleetSnapshot(
        device: FleetDeviceInfo(
          deviceId: identity.deviceId,
          idSource: identity.idSource,
          serial: identity.serial,
          appType: _appType,
          storeId: appState.storeId,
          storeName: appState.storeName,
          appVersion: device.appVersion,
          buildNumber: device.buildNumber,
          platform: device.platform,
          osVersion: device.osVersion,
          deviceModel: device.deviceModel,
          deviceManufacturer: device.deviceManufacturer,
          environment: _environment(),
        ),
        runtime: FleetRuntime(
          status: FleetStatus.online,
          lifecycle: lifecycle,
          socketConnected: socketConnected,
          mode: appState.mode,
          businessOpen: appState.businessOpen,
          connection: await _readConnection(),
          commandRunning: commandRunningProbe?.call() ?? false,
          extra: extra,
        ),
      );
    } catch (e) {
      // 관제가 앱을 막으면 안 된다. 조용히 건너뛰고 다음 틱에 재시도한다.
      _logger?.error('[Fleet] 스냅샷 생성 실패 — 이번 틱 건너뜀', e);
      return null;
    }
  }

  /// 스칼라 1단계만 허용하고, 직렬화 크기가 [FleetRuntime.extraMaxBytes] 를
  /// 넘으면 통째로 버린다(throw 하지 않는다) — extra 는 진단 편의 값이지
  /// 관제 자체를 막을 이유가 아니다.
  Map<String, Object?> _sanitizeExtra(Map<String, Object?> raw) {
    if (raw.isEmpty) return const {};
    final sanitized = <String, Object?>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value == null || value is String || value is num || value is bool) {
        sanitized[entry.key] = value;
      } else {
        _logger?.warn(
          '[Fleet] extra["${entry.key}"] 비스칼라 값 — 제외: ${value.runtimeType}',
        );
      }
    }
    final approxBytes = sanitized.entries
        .map((e) => e.key.length + (e.value?.toString().length ?? 0))
        .fold<int>(0, (a, b) => a + b);
    if (approxBytes > FleetRuntime.extraMaxBytes) {
      _logger?.warn(
        '[Fleet] extra 크기 초과($approxBytes > ${FleetRuntime.extraMaxBytes}) — 이번 틱 제외',
      );
      return const {};
    }
    return sanitized;
  }

  static Future<String?> _defaultReadConnection() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.isEmpty) return null;
      if (results.every((r) => r == ConnectivityResult.none)) return 'none';
      // 유선 > wifi > 모바일 순으로 대표값 하나만 보고한다.
      for (final preferred in [
        ConnectivityResult.ethernet,
        ConnectivityResult.wifi,
        ConnectivityResult.mobile,
      ]) {
        if (results.contains(preferred)) return preferred.name;
      }
      return results.first.name;
    } catch (_) {
      return null;
    }
  }
}
