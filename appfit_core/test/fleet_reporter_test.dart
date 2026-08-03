// fake_async 는 flutter_test 의 전이 의존성(pubspec.lock 에 고정)이며,
// FleetReporter 는 DateTime.now() 를 전혀 읽지 않는 순수 Timer 구성이라
// 가상 시계로 전 시나리오를 결정론적으로 검증할 수 있다.
// ignore_for_file: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

const _interval = Duration(seconds: 60);

FleetDeviceInfo _device({
  String storeId = 'MATA00001',
  String appVersion = '3.2.1',
  String deviceId = 'DE33256H10784',
}) =>
    FleetDeviceInfo(
      deviceId: deviceId,
      idSource: 'serial',
      serial: deviceId,
      appType: 'ORDER_AGENT',
      storeId: storeId,
      storeName: '마타 강남점',
      appVersion: appVersion,
      buildNumber: '412',
      platform: 'android',
      osVersion: '13',
      deviceModel: 'SUNMI D3 MINI',
      deviceManufacturer: 'SUNMI',
      environment: 'live',
    );

FleetSnapshot _snapshot(FleetDeviceInfo device) => FleetSnapshot(
      device: device,
      runtime: const FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: true,
        mode: 'MAIN',
      ),
    );

/// 호출 순서와 인자를 기록하고, 대본대로 응답을 돌려주는 sink.
class _FakeSink implements FleetSink {
  final List<String> calls = [];
  final List<List<FleetCommandResult>> sentResults = [];
  final List<FleetStatus> sentStatuses = [];

  /// 호출 n회차(0-based)에 돌려줄 응답. null 이면 기본 성공.
  FleetAck Function(int call)? script;

  int _calls = 0;

  @override
  String get name => 'Fake';

  @override
  bool get isConfigured => true;

  @override
  Future<FleetAck> register(FleetDeviceInfo device) async {
    calls.add('register');
    return script?.call(_calls++) ?? const FleetAck(success: true);
  }

  @override
  Future<FleetAck> heartbeat(
    FleetSnapshot snapshot,
    List<FleetCommandResult> results,
  ) async {
    calls.add('heartbeat');
    sentResults.add(List.of(results));
    sentStatuses.add(snapshot.runtime.status);
    return script?.call(_calls++) ?? const FleetAck(success: true);
  }
}

FleetAck _ackWith({
  List<FleetCommand> commands = const [],
  int? nextInterval,
  bool needsRegister = false,
}) =>
    FleetAck(
      success: true,
      commands: commands,
      nextIntervalSeconds: nextInterval,
      needsRegister: needsRegister,
    );

void main() {
  group('보고 케이던스', () {
    test('첫 틱은 register, 이후는 interval 마다 heartbeat', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(sink.calls, ['register'], reason: '지문이 비어 있으므로 첫 보고는 register');

        async.elapse(_interval);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, ['register', 'heartbeat', 'heartbeat']);

        reporter.stop();
      });
    });

    test('stop() 이후에는 틱이 멈춘다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        reporter.stop();

        async.elapse(_interval * 5);
        async.flushMicrotasks();
        expect(sink.calls, ['register']);
      });
    });

    test('snapshotBuilder 가 null 이면 전송하지 않고 백오프도 하지 않는다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        var ready = false;
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => ready ? _snapshot(_device()) : null,
          isOnline: () async => true,
          interval: _interval,
        )..start();

        // 준비 전 3틱 — sink 호출 0회.
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval * 3);
        async.flushMicrotasks();
        expect(sink.calls, isEmpty);

        // 준비되면 다음 틱에 곧바로 보고한다 = 간격이 벌어지지 않았다(백오프 없음).
        ready = true;
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, ['register']);

        reporter.stop();
      });
    });
  });

  group('재등록 판정', () {
    test('정적 정보(storeId)가 바뀌면 heartbeat 대신 register', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        var storeId = 'MATA00001';
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device(storeId: storeId)),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, ['register', 'heartbeat']);

        storeId = 'PAIK00007'; // 매장 전환
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls.last, 'register');

        // 지문이 다시 안정되면 heartbeat 로 복귀.
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls.last, 'heartbeat');

        reporter.stop();
      });
    });

    test('invalidateRegistration() 은 다음 틱을 register 로 만든다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, ['register', 'heartbeat']);

        reporter.invalidateRegistration();
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls.last, 'register');

        reporter.stop();
      });
    });

    test('서버가 needsRegister 를 주면 다음 틱에 다시 등록한다 (DB 초기화 자가 치유)', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        // 0: register 성공 → 1: heartbeat 인데 서버가 기기를 모름
        sink.script =
            (n) => n == 1 ? _ackWith(needsRegister: true) : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, ['register', 'heartbeat']);

        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls.last, 'register',
            reason: 'needsRegister 를 받으면 지문을 버린다');

        reporter.stop();
      });
    });
  });

  group('실패 백오프', () {
    test('연속 실패 시 60→120→240 으로 늘고 성공하면 60 으로 복귀', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final tickAt = <int>[];
        var failing = true;

        sink.script = (_) => failing
            ? const FleetAck.fail('boom')
            : const FleetAck(success: true);

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async {
            tickAt.add(async.elapsed.inSeconds);
            return _snapshot(_device());
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks(); // t=0 실패 1회
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks(); // t=120 실패 2회
        async.elapse(const Duration(seconds: 240));
        async.flushMicrotasks(); // t=360 실패 3회
        expect(tickAt, [0, 120, 360], reason: '지수 백오프: 60*2, 60*4, 60*8');

        failing = false;
        async.elapse(const Duration(seconds: 480));
        async.flushMicrotasks(); // t=840 성공
        expect(tickAt.last, 840);

        // 성공 후엔 기본 간격으로 복귀.
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(tickAt.last, 900);

        reporter.stop();
      });
    });

    test('백오프는 maxBackoff 를 넘지 않는다', () {
      fakeAsync((async) {
        final sink = _FakeSink()..script = (_) => const FleetAck.fail('boom');
        final tickAt = <int>[];

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async {
            tickAt.add(async.elapsed.inSeconds);
            return _snapshot(_device());
          },
          isOnline: () async => true,
          interval: _interval,
          maxBackoff: const Duration(seconds: 200),
        )..start();

        async.elapse(const Duration(seconds: 2000));
        async.flushMicrotasks();

        final gaps = [
          for (var i = 1; i < tickAt.length; i++) tickAt[i] - tickAt[i - 1],
        ];
        expect(gaps.every((g) => g <= 200), isTrue);
        expect(gaps.last, 200, reason: '상한에 도달하면 그대로 유지');

        reporter.stop();
      });
    });

    test('4xx(계약 위반)는 점진 백오프 없이 곧바로 상한으로 간다', () {
      fakeAsync((async) {
        final sink = _FakeSink()
          ..script = (_) => const FleetAck.fail('HTTP 401', permanent: true);
        final tickAt = <int>[];

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async {
            tickAt.add(async.elapsed.inSeconds);
            return _snapshot(_device());
          },
          isOnline: () async => true,
          interval: _interval,
          maxBackoff: const Duration(seconds: 600),
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 600));
        async.flushMicrotasks();
        expect(tickAt, [0, 600], reason: '첫 실패부터 상한(600s). 120s 를 거치지 않는다');

        reporter.stop();
      });
    });

    test('snapshotBuilder 가 throw 해도 예외가 밖으로 나가지 않고 타이머가 산다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        var count = 0;
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async {
            count++;
            if (count == 1) throw StateError('부팅 중');
            return _snapshot(_device());
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(sink.calls, isEmpty);

        // 예외는 실패로 세므로 다음 틱은 120초 뒤.
        async.elapse(const Duration(seconds: 120));
        async.flushMicrotasks();
        expect(sink.calls, ['register'], reason: '타이머가 살아 있어 복구된다');

        reporter.stop();
      });
    });
  });

  group('오프라인', () {
    test('오프라인이면 2틱 건너뛰고 3틱째에 강제 프로브한다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => false,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(sink.calls, isEmpty, reason: '1틱: 스킵');

        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, isEmpty, reason: '2틱: 스킵');

        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls, ['register'],
            reason: '3틱: connectivity 오판(Windows 유선망 등)에 대비한 강제 프로브');

        reporter.stop();
      });
    });
  });

  group('서버 지시 케이던스', () {
    test('nextIntervalSeconds 를 반영하되 [15,600] 으로 클램프한다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final tickAt = <int>[];
        var next = 15;
        sink.script = (_) => _ackWith(nextInterval: next);

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async {
            tickAt.add(async.elapsed.inSeconds);
            return _snapshot(_device());
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(tickAt, [0, 15], reason: '서버가 15초를 지시하면 따른다');

        // 서버 버그로 1초가 와도 15초 밑으로는 내려가지 않는다.
        next = 1;
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(tickAt, [0, 15, 30, 45], reason: '1초 지시는 15초로 클램프');

        reporter.stop();
      });
    });
  });

  group('명령', () {
    test('명령을 실행하고 결과를 다음 heartbeat 에 실어 보낸다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final handled = <String>[];
        sink.script = (n) => n == 1
            ? _ackWith(commands: [
                const FleetCommand(
                    commandId: 'c-1', type: FleetCommandTypes.ping),
              ])
            : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          commandHandler: (c) async {
            handled.add(c.commandId);
            return FleetCommandResult.ok(c.commandId, message: '3개 파일');
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks(); // register
        async.elapse(_interval);
        async.flushMicrotasks(); // heartbeat → 명령 수신 → 실행 → flushNow
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(handled, ['c-1']);
        final withResults =
            sink.sentResults.where((r) => r.isNotEmpty).toList();
        expect(withResults, hasLength(1));
        expect(withResults.single.single.commandId, 'c-1');
        expect(withResults.single.single.code, FleetResultCodes.ok);
        expect(withResults.single.single.message, '3개 파일');

        reporter.stop();
      });
    });

    test('같은 commandId 가 재배달되면 다시 실행하지 않는다 (Slack 이중 업로드 방지)', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final handled = <String>[];
        const dup =
            FleetCommand(commandId: 'c-dup', type: FleetCommandTypes.ping);
        // 1회차와 2회차 heartbeat 가 같은 명령을 실어 온다.
        sink.script =
            (n) => (n == 1 || n == 2) ? _ackWith(commands: [dup]) : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          commandHandler: (c) async {
            handled.add(c.commandId);
            return FleetCommandResult.ok(c.commandId);
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval * 3);
        async.flushMicrotasks();

        expect(handled, ['c-dup'], reason: '두 번 배달돼도 실행은 1회');

        reporter.stop();
      });
    });

    test('핸들러 미주입이면 즉시 UNSUPPORTED 로 답한다 (delivered 좀비 방지)', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        sink.script = (n) => n == 1
            ? _ackWith(commands: [
                const FleetCommand(
                    commandId: 'c-9', type: FleetCommandTypes.logUpload),
              ])
            : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        final results = sink.sentResults.expand((r) => r).toList();
        expect(results.single.code, FleetResultCodes.unsupported);
        expect(results.single.success, isFalse);

        reporter.stop();
      });
    });

    test('핸들러가 throw 하면 FAILED 결과를 만들고 리포터는 계속 돈다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        sink.script = (n) => n == 1
            ? _ackWith(commands: [
                const FleetCommand(
                    commandId: 'c-err', type: FleetCommandTypes.logUpload),
              ])
            : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          commandHandler: (c) async => throw StateError('디스크 없음'),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        final results = sink.sentResults.expand((r) => r).toList();
        expect(results.single.code, FleetResultCodes.failed);
        expect(results.single.message, contains('디스크 없음'));

        // 타이머 생존 확인.
        final before = sink.calls.length;
        async.elapse(_interval);
        async.flushMicrotasks();
        expect(sink.calls.length, greaterThan(before));

        reporter.stop();
      });
    });

    test('대상이 현재 기기·매장과 다르면 실행하지 않고 INVALID_TARGET', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        var handled = 0;
        sink.script = (n) => n == 1
            ? _ackWith(commands: [
                const FleetCommand(
                  commandId: 'c-stale',
                  type: FleetCommandTypes.logUpload,
                  // 매장 전환 전에 큐잉된 구 바인딩 명령.
                  payload: {'storeId': 'OLD00001', 'deviceId': 'DE33256H10784'},
                ),
              ])
            : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device(storeId: 'MATA00001')),
          commandHandler: (c) async {
            handled++;
            return FleetCommandResult.ok(c.commandId);
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(handled, 0, reason: '엉뚱한 매장 로그가 Slack 에 올라가면 안 된다');
        final results = sink.sentResults.expand((r) => r).toList();
        expect(results.single.code, FleetResultCodes.invalidTarget);

        reporter.stop();
      });
    });

    test('명령 실행이 길어도 heartbeat 케이던스가 유지된다 (stale 오탐 방지)', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        sink.script = (n) => n == 1
            ? _ackWith(commands: [
                const FleetCommand(
                    commandId: 'c-slow', type: FleetCommandTypes.logUpload),
              ])
            : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          // 로그 zip 수집이 3분 걸리는 상황.
          commandHandler: (c) async {
            await Future<void>.delayed(const Duration(minutes: 3));
            return FleetCommandResult.ok(c.commandId);
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks(); // 명령 수신, 실행 시작(await 하지 않음)

        final callsBefore = sink.calls.length;
        async.elapse(const Duration(minutes: 2));
        async.flushMicrotasks();

        expect(sink.calls.length - callsBefore, 2,
            reason: '명령이 도는 동안에도 60초마다 heartbeat 가 나가야 stale 로 안 보인다');

        reporter.stop();
      });
    });

    test('동시에 온 명령 중 하나만 실행하고 나머지는 BUSY 로 답한다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        var handled = 0;
        sink.script = (n) => n == 1
            ? _ackWith(commands: const [
                FleetCommand(
                    commandId: 'c-a', type: FleetCommandTypes.logUpload),
                FleetCommand(
                    commandId: 'c-b', type: FleetCommandTypes.logUpload),
              ])
            : _ackWith();

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          commandHandler: (c) async {
            handled++;
            await Future<void>.delayed(const Duration(seconds: 30));
            return FleetCommandResult.ok(c.commandId);
          },
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(handled, 1);
        final results = sink.sentResults.expand((r) => r).toList();
        expect(results.map((r) => r.code),
            containsAll([FleetResultCodes.ok, FleetResultCodes.busy]));

        reporter.stop();
      });
    });

    test('결과 버퍼는 상한을 넘지 않는다 (오래된 것부터 폐기)', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        // 전송은 계속 실패시켜 결과가 버퍼에 쌓이게 한다.
        var call = 0;
        sink.script = (n) {
          call = n;
          if (n == 1) {
            return _ackWith(commands: [
              for (var i = 0; i < 6; i++)
                FleetCommand(commandId: 'c-$i', type: FleetCommandTypes.ping),
            ]);
          }
          return const FleetAck.fail('네트워크 끊김');
        };

        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          commandHandler: (c) async => FleetCommandResult.ok(c.commandId),
          isOnline: () async => true,
          interval: _interval,
          maxPendingResults: 3,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();
        async.elapse(_interval);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 30));
        async.flushMicrotasks();

        expect(call, greaterThan(1));
        final lastSent = sink.sentResults.where((r) => r.isNotEmpty).last;
        expect(lastSent.length, lessThanOrEqualTo(3));

        reporter.stop();
      });
    });
  });

  group('종료 보고', () {
    test('reportClosing() 은 status=closing 으로 1회만 보낸다', () {
      fakeAsync((async) {
        final sink = _FakeSink();
        final reporter = FleetReporter(
          sink: sink,
          snapshotBuilder: () async => _snapshot(_device()),
          isOnline: () async => true,
          interval: _interval,
        )..start();

        async.elapse(Duration.zero);
        async.flushMicrotasks();

        reporter.reportClosing();
        async.flushMicrotasks();
        reporter.reportClosing(); // 두 번째는 무시
        async.flushMicrotasks();

        expect(sink.sentStatuses, [FleetStatus.closing]);

        reporter.stop();
      });
    });
  });
}
