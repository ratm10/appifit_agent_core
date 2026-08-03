import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'package:appfit_core/src/config/sync_intervals.dart';
import 'package:appfit_core/src/fleet/fleet_models.dart';
import 'package:appfit_core/src/fleet/fleet_sink.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// 보고할 스냅샷을 만든다. `null` 은 "아직 준비 안 됨"이며 실패가 아니다.
///
/// 동기 getter 묶음이 아니라 async 콜백인 이유: 기기 식별자 해석(네이티브 시리얼
/// 조회)이 비동기이고, storeId/storeName 은 로그인 후에야 채워지기 때문이다.
/// 호출 시점에 값을 읽으므로 로그인 지연과 매장 전환이 저절로 해결된다.
typedef FleetSnapshotBuilder = Future<FleetSnapshot?> Function();

/// 원격 명령 실행기. 미주입이면 모든 명령에 UNSUPPORTED 로 답한다.
typedef FleetCommandHandler = Future<FleetCommandResult> Function(
    FleetCommand command);

typedef FleetOnlineCheck = Future<bool> Function();

/// 기기 상태를 주기적으로 서버에 보고하고, 응답에 실려 온 명령을 실행한다.
///
/// 설계 원칙 셋:
///
/// 1. **[DateTime.now] 를 쓰지 않는다.** 재등록 판정은 지문 문자열 비교, 백오프는
///    실패 횟수 정수 연산, 중복 명령 차단은 ID 큐다. 전부 시계와 무관하므로
///    `fakeAsync` 가상시계로 전 시나리오를 검증할 수 있다.
/// 2. **[Timer.periodic] 을 쓰지 않는다.** 매 틱 끝에서 단발 타이머를 다시 건다.
///    간격을 동적으로 바꿀 수 있고, 응답이 느려도 틱이 누적되지 않는다.
/// 3. **예외가 밖으로 나가지 않는다.** 관제가 주문 흐름을 막으면 안 된다.
class FleetReporter {
  final FleetSink _sink;
  final FleetSnapshotBuilder _snapshotBuilder;
  final FleetCommandHandler? _commandHandler;
  final FleetOnlineCheck _isOnline;
  final AppFitLogger? _logger;

  final Duration _maxBackoff;
  final int _minIntervalSec;
  final int _maxIntervalSec;
  final int _maxPendingResults;
  final int _seenCommandCap;
  final int _jitterMs;
  final Random _random;

  /// 오프라인이어도 이 횟수마다 한 번은 실제로 전송을 시도한다.
  /// connectivity_plus 가 Windows 유선망을 none 으로 오판해도 자가 치유되게.
  static const int _offlineProbeEvery = 3;

  Duration _baseInterval;
  Timer? _timer;
  bool _running = false;
  bool _busy = false;
  bool _flushRequested = false;
  bool _commandBusy = false;
  bool _closingSent = false;

  String? _lastFingerprint;
  FleetDeviceInfo? _lastDevice;
  int _consecutiveFailures = 0;
  bool _permanentFailure = false;
  int _offlineSkips = 0;

  final List<FleetCommandResult> _pendingResults = [];
  final Queue<String> _seenCommandIds = ListQueue<String>();

  FleetReporter({
    required FleetSink sink,
    required FleetSnapshotBuilder snapshotBuilder,
    FleetCommandHandler? commandHandler,
    FleetOnlineCheck? isOnline,
    AppFitLogger? logger,
    Duration interval = AppFitSyncIntervals.connectedInterval,
    Duration maxBackoff = const Duration(minutes: 10),
    int minIntervalSeconds = 15,
    int maxIntervalSeconds = 600,
    int maxPendingResults = 8,
    int seenCommandCap = 32,

    /// 첫 틱을 0~[jitterMs] 만큼 흩뜨린다. 정전 복구로 매장 기기가 한꺼번에
    /// 부팅할 때 동기화된 스파이크를 막는다. 테스트에서는 0(결정적).
    int jitterMs = 0,
    Random? random,
  })  : _sink = sink,
        _snapshotBuilder = snapshotBuilder,
        _commandHandler = commandHandler,
        _isOnline = isOnline ?? _defaultIsOnline,
        _logger = logger,
        _baseInterval = interval,
        _maxBackoff = maxBackoff,
        _minIntervalSec = minIntervalSeconds,
        _maxIntervalSec = maxIntervalSeconds,
        _maxPendingResults = maxPendingResults,
        _seenCommandCap = seenCommandCap,
        _jitterMs = jitterMs,
        _random = random ?? Random();

  bool get isRunning => _running;

  /// 장시간 명령이 진행 중인지. 스냅샷 builder 가 `commandRunning` 에 채운다.
  bool get isCommandRunning => _commandBusy;

  void start() {
    if (_running) return;
    _running = true;
    _closingSent = false;
    final jitter = _jitterMs > 0
        ? Duration(milliseconds: _random.nextInt(_jitterMs))
        : Duration.zero;
    _schedule(jitter);
  }

  Future<void> stop() async {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 다음 틱을 즉시 앞당긴다. 명령 완료 직후 결과를 바로 올리는 용도.
  void flushNow() {
    if (!_running) return;
    if (_busy) {
      // 진행 중인 틱이 끝나면서 Duration.zero 로 재예약한다.
      _flushRequested = true;
      return;
    }
    _schedule(Duration.zero);
  }

  /// 다음 틱에 heartbeat 대신 register 를 보내게 한다.
  /// 매장이 바뀌었거나 서버가 이 기기를 모를 때.
  void invalidateRegistration() {
    _lastFingerprint = null;
  }

  /// 종료 직전 best-effort 1회. 타이머를 우회하고 3초 안에 끝낸다.
  ///
  /// Android 가 isolate 를 먼저 죽여 전송이 안 되는 건 정상이며, 그 경우는
  /// 서버의 stale/offline 임계값이 받아낸다.
  Future<void> reportClosing() async {
    if (_closingSent) return;
    _closingSent = true;
    try {
      final snapshot = await _snapshotBuilder();
      if (snapshot == null) return;
      await _sink.heartbeat(
        FleetSnapshot(
          device: snapshot.device,
          runtime: snapshot.runtime.copyWith(status: FleetStatus.closing),
        ),
        const [],
      ).timeout(const Duration(seconds: 3));
      _logger?.debug('[Fleet] closing 보고 완료');
    } catch (e) {
      _logger?.debug('[Fleet] closing 보고 실패(정상 가능): $e');
    }
  }

  // ── 틱 ─────────────────────────────────────────────────────────────────────

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(delay, _tick);
  }

  /// 실패 횟수만으로 계산하는 지수 백오프. 시계를 읽지 않는다.
  Duration get _currentInterval {
    if (_consecutiveFailures <= 0) return _baseInterval;
    // 계약 위반(4xx)은 재시도해도 고쳐지지 않으므로 곧바로 상한으로 간다.
    if (_permanentFailure) return _maxBackoff;
    final scaled = _baseInterval * (1 << _consecutiveFailures.clamp(1, 16));
    return scaled > _maxBackoff ? _maxBackoff : scaled;
  }

  Future<void> _tick() async {
    if (!_running) return;
    // 진행 중인 틱의 finally 가 다음을 예약하므로 여기서 재예약하면 중복된다.
    if (_busy) return;

    _busy = true;
    try {
      if (!await _isOnline()) {
        _offlineSkips++;
        if (_offlineSkips < _offlineProbeEvery) {
          _logger?.debug('[Fleet] 오프라인 — 틱 스킵 ($_offlineSkips)');
          return;
        }
        _logger?.debug('[Fleet] 오프라인이지만 강제 프로브');
      }
      _offlineSkips = 0;

      final snapshot = await _snapshotBuilder();
      if (snapshot == null) {
        // 아직 준비 안 됨(부팅 직후 등). 실패가 아니므로 백오프하지 않는다.
        return;
      }
      _lastDevice = snapshot.device;

      final fingerprint = snapshot.device.fingerprint;
      final needsRegister = _lastFingerprint != fingerprint;
      final sending = List<FleetCommandResult>.unmodifiable(_pendingResults);

      final ack = needsRegister
          ? await _sink.register(snapshot.device)
          : await _sink.heartbeat(snapshot, sending);

      if (!ack.success) {
        _consecutiveFailures++;
        _permanentFailure = ack.permanent;
        _logger?.warn('[Fleet] 보고 실패 ($_consecutiveFailures회): ${ack.error}');
        return;
      }

      _consecutiveFailures = 0;
      _permanentFailure = false;
      _lastFingerprint = fingerprint;

      // 서버가 이 기기를 모른다 → 다음 틱에 register.
      if (ack.needsRegister) _lastFingerprint = null;

      if (sending.isNotEmpty) {
        final sentIds = sending.map((r) => r.commandId).toSet();
        _pendingResults.removeWhere((r) => sentIds.contains(r.commandId));
      }

      _applyServerInterval(ack.nextIntervalSeconds);

      // ★ await 하지 않는다. 로그 zip 수집이 30초 걸려도 heartbeat 케이던스가
      //   유지되어 기기가 대시보드에서 stale 로 보이지 않는다.
      _dispatch(ack.commands);
    } catch (e) {
      _consecutiveFailures++;
      _logger?.warn('[Fleet] 틱 예외 ($_consecutiveFailures회): $e');
    } finally {
      _busy = false;
      final next = _flushRequested ? Duration.zero : _currentInterval;
      _flushRequested = false;
      _schedule(next);
    }
  }

  void _applyServerInterval(int? seconds) {
    if (seconds == null) return;
    // 클램프가 없으면 서버 버그 하나로 전 기기가 1초 폴링을 시작한다.
    final clamped = seconds.clamp(_minIntervalSec, _maxIntervalSec);
    _baseInterval = Duration(seconds: clamped);
  }

  // ── 명령 ───────────────────────────────────────────────────────────────────

  void _dispatch(List<FleetCommand> commands) {
    for (final command in commands) {
      if (_seenCommandIds.contains(command.commandId)) {
        _logger?.debug('[Fleet] 이미 처리한 명령 무시: ${command.commandId}');
        continue;
      }
      _seenCommandIds.addLast(command.commandId);
      while (_seenCommandIds.length > _seenCommandCap) {
        _seenCommandIds.removeFirst();
      }
      unawaited(_runCommand(command));
    }
  }

  Future<void> _runCommand(FleetCommand command) async {
    // 대상 검증. 매장 전환 직후 in-flight 였던 구 바인딩 명령이 엉뚱한 매장
    // 로그를 Slack 에 올리는 사고를 여기서 끊는다.
    final device = _lastDevice;
    if (device != null) {
      final targetDevice = command.targetDeviceId;
      final targetStore = command.targetStoreId;
      if ((targetDevice != null && targetDevice != device.deviceId) ||
          (targetStore != null && targetStore != device.storeId)) {
        _finish(FleetCommandResult.invalidTarget(
          command.commandId,
          message: '대상 불일치 (요청 기기=$targetDevice, 매장=$targetStore)',
        ));
        return;
      }
    }

    if (_commandBusy) {
      _finish(
          FleetCommandResult.busy(command.commandId, message: '다른 명령 실행 중'));
      return;
    }

    _commandBusy = true;
    try {
      final handler = _commandHandler;
      // 핸들러 미주입 시 즉시 UNSUPPORTED. 이게 없으면 로그 수집 기능이 없는
      // 앱(DID 등)에 명령이 잘못 가면 서버에서 delivered 인 채로 만료까지 매달린다.
      final result = handler == null
          ? FleetCommandResult.unsupported(
              command.commandId,
              message: '${device?.appType ?? '이'} 앱은 원격 명령을 지원하지 않습니다.',
            )
          : await handler(command);
      _finish(result);
    } catch (e) {
      _finish(FleetCommandResult.failed(command.commandId, '$e'));
    } finally {
      _commandBusy = false;
    }
  }

  void _finish(FleetCommandResult result) {
    _pendingResults.add(result);
    while (_pendingResults.length > _maxPendingResults) {
      final dropped = _pendingResults.removeAt(0);
      _logger?.warn('[Fleet] 결과 버퍼 초과 — 폐기: $dropped');
    }
    _logger?.debug('[Fleet] 명령 종료: $result');
    flushNow();
  }

  static Future<bool> _defaultIsOnline() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // 판정 자체가 실패하면 시도하는 쪽으로 기운다. 무보고가 더 나쁘다.
      return true;
    }
  }
}
