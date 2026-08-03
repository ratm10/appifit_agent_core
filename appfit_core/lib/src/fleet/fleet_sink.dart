import 'package:appfit_core/src/fleet/fleet_models.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// 기기 보고의 전송 목적지.
///
/// 명령 결과를 올리는 전용 메서드(`ackCommand`)를 두지 않고 [heartbeat] 의
/// `results` 에 실어 보낸다. 엔드포인트가 하나 줄고, 전송이 실패해도 결과가
/// 버퍼에 남아 다음 틱에 자동 재시도되는 성질이 공짜로 따라온다.
abstract class FleetSink {
  /// 로깅/표시용 이름.
  String get name;

  /// 목적지 설정이 갖춰졌는지. false 면 리포터가 전송을 시도하지 않는다.
  bool get isConfigured;

  Future<FleetAck> register(FleetDeviceInfo device);

  Future<FleetAck> heartbeat(
      FleetSnapshot snapshot, List<FleetCommandResult> results);
}

/// 기본값. 백엔드가 설정되지 않은 빌드(FLEET_BASE_URL 미주입)에서 쓰인다.
///
/// 관제를 끄는 게 아니라 **무해하게 만드는** 것이 목적이다. 리포터는 평소대로
/// 돌고 전송만 로그로 흘리므로, 설정이 빠진 빌드에서도 앱 동작이 달라지지 않는다.
class NoopFleetSink implements FleetSink {
  final AppFitLogger? _logger;

  NoopFleetSink({AppFitLogger? logger}) : _logger = logger;

  @override
  String get name => 'Noop';

  @override
  bool get isConfigured => false;

  @override
  Future<FleetAck> register(FleetDeviceInfo device) async {
    _logger?.debug('[Fleet] (noop) register $device');
    return const FleetAck(success: true);
  }

  @override
  Future<FleetAck> heartbeat(
    FleetSnapshot snapshot,
    List<FleetCommandResult> results,
  ) async {
    _logger?.debug(
      '[Fleet] (noop) heartbeat ${snapshot.device.appType}/${snapshot.device.deviceId} '
      'status=${snapshot.runtime.status.value} results=${results.length}',
    );
    return const FleetAck(success: true);
  }
}
