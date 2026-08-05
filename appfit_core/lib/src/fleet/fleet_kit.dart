import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:appfit_core/src/config/sync_intervals.dart';
import 'package:appfit_core/src/device/device_probe.dart';
import 'package:appfit_core/src/fleet/fleet_app_state.dart';
import 'package:appfit_core/src/fleet/fleet_connection_status.dart';
import 'package:appfit_core/src/fleet/fleet_identity.dart';
import 'package:appfit_core/src/fleet/fleet_reporter.dart';
import 'package:appfit_core/src/fleet/fleet_sink.dart';
import 'package:appfit_core/src/fleet/fleet_snapshot_assembler.dart';
import 'package:appfit_core/src/fleet/http_fleet_sink.dart';
import 'package:appfit_core/src/fleet/observing_fleet_sink.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// 기기 관제(Fleet) 채택 파사드. 정적 기기정보 수집·식별자 조달·연결성 판정·
/// 라이프사이클 관찰·sink 조립·연결상태 노출을 전부 이 클래스가 소유하고,
/// 앱은 [appType] 문자열 하나와 [readAppState] 클로저 하나만 준다.
///
/// 목적지와 식별자는 각각 **배타적 슬롯**이다:
/// - [sink] 를 주면 [baseUrl]/[deviceKey] 는 비워야 한다.
/// - [identity] 를 주면 [nativeSerial]/[identityStore] 는 주지 않는다.
///
/// 두 규칙 모두 assert 로 강제한다 — "안 주면 core 가 폴백"이라는 계층형
/// 구조를 만들지 않기 위해서다. 그런 계층형은 정본이 둘로 갈라지는 시나리오
/// 그 자체다(자세한 이유는 [FleetIdentityResolver] 문서 참고).
class FleetKit with WidgetsBindingObserver {
  final AppFitLogger? _logger;
  final FleetIdentityResolver _identity;
  late final FleetSink _sink;
  late final FleetSnapshotAssembler _assembler;
  late final FleetReporter _reporter;
  final ValueNotifier<FleetConnectionStatus> _connectionStatus;
  final bool _observeLifecycle;
  bool _observerRegistered = false;

  FleetKit({
    required String appType,
    required FleetAppStateReader readAppState,
    String baseUrl = '',
    String deviceKey = '',
    FleetSink? sink,
    FleetIdentityResolver? identity,
    FleetNativeSerialReader? nativeSerial,
    FleetIdentityStore? identityStore,
    AppFitDeviceProbe? deviceProbe,
    FleetCommandHandler? commandHandler,
    AppFitLogger? logger,
    Duration interval = AppFitSyncIntervals.connectedInterval,
    int jitterMs = 15000,
    bool observeLifecycle = true,

    /// 테스트 주입점. 기본은 connectivity_plus 판정([FleetReporter] 기본값).
    FleetOnlineCheck? isOnline,

    /// 테스트 주입점. 기본은 connectivity_plus 기반 유선/wifi/모바일 판정.
    Future<String?> Function()? readConnection,
  })  : assert(
          sink == null || (baseUrl.isEmpty && deviceKey.isEmpty),
          'sink 와 baseUrl/deviceKey 를 동시에 주지 마세요 — 목적지 슬롯은 배타적입니다.',
        ),
        assert(
          identity == null || (nativeSerial == null && identityStore == null),
          'identity 와 nativeSerial/identityStore 를 동시에 주지 마세요 — '
          '식별자 정본이 둘로 갈라집니다.',
        ),
        _logger = logger,
        _observeLifecycle = observeLifecycle,
        _connectionStatus = ValueNotifier(
          sink != null || (baseUrl.isNotEmpty && deviceKey.isNotEmpty)
              ? FleetConnectionStatus.connecting
              : FleetConnectionStatus.disabled,
        ),
        _identity = identity ??
            DefaultFleetIdentityResolver(
              probe: deviceProbe ?? PlatformDeviceProbe(logger: logger),
              store: identityStore,
              nativeSerial: nativeSerial,
              logger: logger,
            ) {
    final probe = deviceProbe ?? PlatformDeviceProbe(logger: logger);
    final destination = sink ??
        (baseUrl.isNotEmpty && deviceKey.isNotEmpty
            ? HttpFleetSink(
                baseUrl: baseUrl, deviceKey: deviceKey, logger: logger)
            : NoopFleetSink(logger: logger));

    // 설정 없는 빌드(Noop)는 감싸지 않는다. NoopFleetSink 는 항상
    // success:true 를 돌려주므로, 여기서 감싸면 아무것도 전송하지 않는데도
    // 연결 상태가 "connected" 로 표시되는 오판이 생긴다.
    _sink = destination.isConfigured
        ? ObservingFleetSink(
            inner: destination,
            onStatus: (status) {
              if (_connectionStatus.value != status) {
                _logger?.debug(
                  '[Fleet] 연결 상태 전환: ${_connectionStatus.value.name} → ${status.name}',
                );
              }
              _connectionStatus.value = status;
            },
          )
        : destination;

    _assembler = FleetSnapshotAssembler(
      appType: appType,
      readAppState: readAppState,
      identity: _identity,
      probe: probe,
      readConnection: readConnection,
      logger: logger,
    );

    _reporter = FleetReporter(
      sink: _sink,
      snapshotBuilder: _assembler.build,
      commandHandler: commandHandler,
      isOnline: isOnline,
      logger: logger,
      interval: interval,
      // 정전 복구로 매장 기기가 한꺼번에 부팅할 때 첫 보고가 동시에 몰리지 않게.
      jitterMs: jitterMs,
    );
    // 순환 참조를 피하려고 생성 후에 배선한다(assembler → reporter → assembler).
    _assembler.commandRunningProbe = () => _reporter.isCommandRunning;

    if (_observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observerRegistered = true;
    }
  }

  /// 목적지 설정이 갖춰졌는지(= sink.isConfigured).
  bool get isEnabled => _sink.isConfigured;

  bool get isRunning => _reporter.isRunning;

  /// 앱바 아이콘 등 UI 가 구독하는 연결 상태.
  ValueListenable<FleetConnectionStatus> get connectionStatus =>
      _connectionStatus;

  /// 저수준 접근이 필요할 때의 탈출구.
  FleetReporter get reporter => _reporter;

  void start() => _reporter.start();

  Future<void> stop() => _reporter.stop();

  void flushNow() => _reporter.flushNow();

  /// 소켓 연결 상태를 스냅샷에 반영한다. 앱이 소켓 상태 변화마다 호출한다.
  set socketConnected(bool value) => _assembler.socketConnected = value;

  /// [observeLifecycle] 를 false 로 끈 경우, 앱이 직접 라이프사이클 변화를
  /// 밀어넣는 통로. 두 방식을 동시에 쓰지 않는다.
  set lifecycle(AppLifecycleState value) => _applyLifecycle(value);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _applyLifecycle(state);

  void _applyLifecycle(AppLifecycleState state) {
    _assembler.lifecycle = state.name;
    // paused 는 Android 오버레이 버블 때문에 상시 발생해서 대시보드가
    // "종료 중"으로 도배된다. detached 에서만 closing 을 보낸다.
    if (state == AppLifecycleState.detached) {
      unawaited(_reporter.reportClosing());
    }
  }

  /// 매장/서버 환경 전환 시 호출. 캐시된 식별자를 무효화하고 재등록을
  /// 강제한 뒤 즉시 flush 한다.
  void onStoreChanged() {
    _identity.invalidate();
    _reporter.invalidateRegistration();
    _reporter.flushNow();
  }

  Future<void> reportClosing() => _reporter.reportClosing();

  /// 리포터 정지 + 라이프사이클 옵저버 해제 + 내부 리스너 정리.
  void dispose() {
    unawaited(_reporter.stop());
    if (_observerRegistered) {
      WidgetsBinding.instance.removeObserver(this);
      _observerRegistered = false;
    }
    _connectionStatus.dispose();
  }
}
