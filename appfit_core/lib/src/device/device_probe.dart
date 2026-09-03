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

  /// Windows 전용(`HKLM\SOFTWARE\Microsoft\SQMClient\MachineId`). 다른
  /// 플랫폼에서는 null. **진단 표시용**이다.
  ///
  /// ⚠️ **식별자로 쓰지 말 것.** 하드웨어 파생값이 아니라 OS 설치 이미지에
  /// 박혀 있는 값이라, sysprep 없이 복제 배포된 PC 들은 이 값이 전부 같다.
  /// 실제로 서로 다른 매장의 두 POS 가 같은 값을 보고해 D1 의 기기 행 하나를
  /// 번갈아 덮어쓴 사고가 있었다(경위는 appfit_order_agent 의
  /// docs/DEVICE_MONITORING.md). 식별자는 [FleetIdentityResolver] 가
  /// 시리얼/설치 UUID 로만 조달한다.
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
