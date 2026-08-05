import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:appfit_core/src/logging/appfit_logger.dart';

/// 기계적으로 수집 가능한 기기·앱 정보 묶음. Fleet 과 향후 Monitoring 이
/// 공유하는 **구현**이다 — 두 기능의 시간 의미(부팅 시 1회 스냅샷 vs 60초
/// 주기 live pull)가 달라 인터페이스 자체는 통합하지 않는다.
class AppFitDeviceInfo {
  /// android | windows | ios | unknown
  final String platform;
  final String osVersion;
  final String deviceModel;
  final String deviceManufacturer;
  final String appVersion;
  final String buildNumber;

  /// Windows 전용(MachineGuid). 다른 플랫폼에서는 null —
  /// [FleetIdentityResolver] 가 식별자 후보로 소비한다.
  final String? windowsMachineGuid;

  const AppFitDeviceInfo({
    required this.platform,
    required this.osVersion,
    required this.deviceModel,
    required this.deviceManufacturer,
    required this.appVersion,
    required this.buildNumber,
    this.windowsMachineGuid,
  });

  @override
  String toString() =>
      'AppFitDeviceInfo($platform, $deviceModel, os=$osVersion, app=$appVersion+$buildNumber)';
}

abstract class AppFitDeviceProbe {
  Future<AppFitDeviceInfo> read();
}

/// device_info_plus + package_info_plus 기반 기본 구현. 1회 조회 후 캐시한다.
class PlatformDeviceProbe implements AppFitDeviceProbe {
  final AppFitLogger? _logger;
  final DeviceInfoPlugin _deviceInfo;
  final Future<PackageInfo> Function() _packageInfo;

  AppFitDeviceInfo? _cached;

  PlatformDeviceProbe({
    AppFitLogger? logger,
    DeviceInfoPlugin? deviceInfo,
    Future<PackageInfo> Function()? packageInfo,
  })  : _logger = logger,
        _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
        _packageInfo = packageInfo ?? PackageInfo.fromPlatform;

  @override
  Future<AppFitDeviceInfo> read() async {
    final cached = _cached;
    if (cached != null) return cached;

    final pkg = await _packageInfo();

    String platform = 'unknown';
    String osVersion = 'unknown';
    String deviceModel = 'Unknown';
    String deviceManufacturer = 'Unknown';
    String? windowsMachineGuid;

    try {
      if (Platform.isAndroid) {
        platform = 'android';
        final info = await _deviceInfo.androidInfo;
        deviceModel = '${info.manufacturer} ${info.model}';
        deviceManufacturer = info.manufacturer;
        osVersion = info.version.release;
      } else if (Platform.isWindows) {
        platform = 'windows';
        final info = await _deviceInfo.windowsInfo;
        deviceModel = info.computerName;
        deviceManufacturer = 'Microsoft';
        osVersion = info.displayVersion.isNotEmpty
            ? info.displayVersion
            : '${info.majorVersion}.${info.minorVersion}.${info.buildNumber}';
        windowsMachineGuid = info.deviceId;
      } else if (Platform.isIOS) {
        platform = 'ios';
        final info = await _deviceInfo.iosInfo;
        deviceModel = info.utsname.machine;
        deviceManufacturer = 'Apple';
        osVersion = info.systemVersion;
      }
    } catch (e) {
      _logger?.error('[DeviceProbe] 기기 정보 조회 실패', e);
    }

    final result = AppFitDeviceInfo(
      platform: platform,
      osVersion: osVersion,
      deviceModel: deviceModel,
      deviceManufacturer: deviceManufacturer,
      appVersion: pkg.version,
      buildNumber: pkg.buildNumber,
      windowsMachineGuid: windowsMachineGuid,
    );
    _cached = result;
    return result;
  }
}
