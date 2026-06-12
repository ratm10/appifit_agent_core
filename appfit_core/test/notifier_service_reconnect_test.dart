import 'dart:async';
import 'dart:io';

import 'package:appfit_core/appfit_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 재연결 상태머신/백오프 characterization 테스트.
//
// [테스트 드라이버 노트] 순수 fakeAsync 클로저 방식 대신 FakeAsync 존 + 실제
// 이벤트루프 양보를 섞은 하이브리드 펌핑을 사용한다. 이유: 연결 성공 후
// 끊김 처리(_cleanupConnection)의 `await subscription.cancel()` 이 onCancel
// 없는 StreamController 의 root-zone `_nullFuture` 를 반환해, 완료 microtask 가
// fakeAsync 큐가 아닌 root 존에 스케줄되기 때문 (flushMicrotasks 로는 진행 불가).

/// 아무것도 출력하지 않는 로거 (테스트 노이즈 억제).
class _SilentLogger implements AppFitLogger {
  const _SilentLogger();

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> error(String message, dynamic error) async {}
}

/// dart:io WebSocket 수동 fake.
///
/// 노티파이어/IOWebSocketChannel 이 실제 사용하는 멤버만 구현하고
/// 나머지는 noSuchMethod 로 막는다 (예상 외 사용 시 즉시 실패).
class _FakeWebSocket extends Stream<dynamic> implements WebSocket {
  final _controller = StreamController<dynamic>();
  final _doneCompleter = Completer<void>();

  /// 테스트가 직접 조작하는 readyState (heartbeat 감지 시나리오용)
  int readyStateValue = WebSocket.open;

  int? _closeCode;
  String? _closeReason;

  @override
  int get readyState => readyStateValue;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  String? get protocol => null;

  @override
  Duration? pingInterval;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<dynamic> close([int? code, String? reason]) {
    readyStateValue = WebSocket.closed;
    _closeCode ??= code;
    _closeReason ??= reason;
    if (!_controller.isClosed) {
      _controller.close();
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
    return _doneCompleter.future;
  }

  @override
  Future<dynamic> get done => _doneCompleter.future;

  /// 서버 측 연결 종료를 흉내낸다 (소켓 스트림 onDone 발화).
  void closeFromServer({int code = 1000, String reason = 'bye'}) {
    _closeCode = code;
    _closeReason = reason;
    readyStateValue = WebSocket.closed;
    if (!_controller.isClosed) {
      _controller.close();
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 시나리오 헬퍼 — FakeAsync 존에서 서비스를 만들고 시도/상태를 기록한다.
///
/// [successScript] 의 n번째 값이 n번째 연결 시도의 성공 여부를 결정하며,
/// 스크립트를 소진하면 마지막 값을 반복한다.
class _Harness {
  _Harness(this.fake, {required List<bool> successScript}) {
    fake.run((_) {
      service = AppFitNotifierService(
        logger: const _SilentLogger(),
        connector: (url, headers) async {
          attemptElapsed.add(fake.elapsed);
          lastHeaders = headers;
          final ok = _cursor < successScript.length
              ? successScript[_cursor]
              : successScript.last;
          _cursor++;
          if (!ok) {
            throw const SocketException('connection refused');
          }
          final socket = _FakeWebSocket();
          sockets.add(socket);
          return socket;
        },
      );
      service.connectionStateStream.listen(statuses.add);
    });
  }

  final FakeAsync fake;
  late final AppFitNotifierService service;
  final List<Duration> attemptElapsed = [];
  final List<ConnectionStatus> statuses = [];
  final List<_FakeWebSocket> sockets = [];
  Map<String, dynamic>? lastHeaders;
  int _cursor = 0;

  int get attempts => attemptElapsed.length;

  /// fakeAsync 큐와 root 존 microtask 를 번갈아 소진한다.
  Future<void> pump({int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      fake.flushMicrotasks();
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 가짜 시간을 진행시킨 뒤 펌핑한다.
  Future<void> elapse(Duration duration) async {
    fake.elapse(duration);
    await pump();
  }

  Future<void> connect() async {
    fake.run((_) {
      service.connect(
        shopCode: 'SHOP1',
        projectId: 'PRJ-001',
        apiKey: 'api-key',
        aesKey: 'abcdefghijklmnopqrstuvwxyz012345', // 32바이트 정상 키
      );
    });
    await pump();
  }

  Future<void> disconnect() async {
    fake.run((_) => service.disconnect());
    await pump();
  }

  Future<void> dispose() async {
    fake.run((_) => service.dispose());
    await pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // connect() 가 등록하는 connectivity_plus EventChannel 리스너가
    // 플랫폼 채널 부재로 에러를 내지 않도록 listen/cancel 을 무응답 성공 처리.
    const codec = StandardMethodCodec();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
      'dev.fluttercommunity.plus/connectivity_status',
      (ByteData? message) async => codec.encodeSuccessEnvelope(null),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'dev.fluttercommunity.plus/connectivity_status', null);
  });

  group('ConnectionStatusExtension.isConnected', () {
    test('connected/initialConnected/reconnected 만 true', () {
      expect(ConnectionStatus.connected.isConnected, true);
      expect(ConnectionStatus.initialConnected.isConnected, true);
      expect(ConnectionStatus.reconnected.isConnected, true);
      expect(ConnectionStatus.reconnecting.isConnected, false);
      expect(ConnectionStatus.disconnected.isConnected, false);
    });
  });

  group('AppFitNotifierService 백오프 재연결', () {
    test('연결 실패 시 3→6→12→24→48초 백오프 후 disconnected 로 전환된다', () async {
      final h = _Harness(FakeAsync(), successScript: [false]);
      await h.connect();

      // 최초 시도 1회 즉시 실패 → reconnecting
      expect(h.attempts, 1);
      expect(h.statuses, [ConnectionStatus.reconnecting]);

      // 백오프: 3, 6, 12, 24, 48초 후 각각 재시도 (총 6회 시도)
      for (final delay in const [3, 6, 12, 24, 48]) {
        await h.elapse(Duration(seconds: delay));
      }
      expect(
        h.attemptElapsed,
        const [
          Duration.zero,
          Duration(seconds: 3),
          Duration(seconds: 9),
          Duration(seconds: 21),
          Duration(seconds: 45),
          Duration(seconds: 93),
        ],
      );

      // 6번째 실패 후 최대 횟수(5회 재시도) 초과 → disconnected
      expect(
        h.statuses,
        List.filled(6, ConnectionStatus.reconnecting) +
            [ConnectionStatus.disconnected],
      );

      // 이후 추가 재시도는 없다
      await h.elapse(const Duration(minutes: 10));
      expect(h.attempts, 6);
    });

    test('백오프 소진 후 notifyNetworkRestored 가 3초 재시도로 다시 시작한다', () async {
      final h = _Harness(FakeAsync(), successScript: [false]);
      await h.connect();
      await h.elapse(const Duration(seconds: 93)); // 백오프 소진
      expect(h.attempts, 6);
      expect(h.statuses.last, ConnectionStatus.disconnected);

      h.fake.run((_) => h.service.notifyNetworkRestored());
      await h.pump();
      expect(h.attempts, 6, reason: '재시도는 초기 지연(3초) 후에 일어난다');

      await h.elapse(const Duration(seconds: 3));
      expect(h.attempts, 7);
      expect(h.attemptElapsed.last, const Duration(seconds: 96));
    });

    test('첫 연결 성공은 initialConnected, 끊김 후 재연결 성공은 reconnected', () async {
      final h = _Harness(FakeAsync(), successScript: [true]);
      await h.connect();
      expect(h.statuses, [ConnectionStatus.initialConnected]);
      expect(h.service.isConnected, true);

      // 서버 측 연결 종료 → reconnecting → 3초 후 재연결 성공
      h.sockets.single.closeFromServer();
      await h.pump();
      expect(h.statuses, [
        ConnectionStatus.initialConnected,
        ConnectionStatus.reconnecting,
      ]);
      expect(h.service.isConnected, false);

      await h.elapse(const Duration(seconds: 3));
      expect(h.statuses.last, ConnectionStatus.reconnected);
      expect(h.service.isConnected, true);
      expect(h.attempts, 2);

      await h.dispose();
    });

    test('현재 동작 고정: 한 번도 연결된 적 없으면 재시도 성공도 reconnected 가 아닌 initialConnected',
        () async {
      final h = _Harness(FakeAsync(), successScript: [false, true]);
      await h.connect();
      await h.elapse(const Duration(seconds: 3));
      expect(h.statuses, [
        ConnectionStatus.reconnecting,
        ConnectionStatus.initialConnected,
      ]);

      await h.dispose();
    });

    test('연결 성공 시 backoff 카운터가 초기화된다 (끊길 때마다 3초부터 다시 시작)', () async {
      final h = _Harness(FakeAsync(), successScript: [false, true, true]);
      await h.connect();
      await h.elapse(const Duration(seconds: 3)); // 2번째 시도에서 성공
      expect(h.statuses.last, ConnectionStatus.initialConnected);

      h.sockets.single.closeFromServer();
      await h.pump();
      await h.elapse(const Duration(seconds: 3)); // 6초가 아닌 3초 후 재시도
      expect(h.statuses.last, ConnectionStatus.reconnected);
      expect(
        h.attemptElapsed.last - h.attemptElapsed[1],
        const Duration(seconds: 3),
      );

      await h.dispose();
    });

    test('heartbeat 가 readyState != open 을 감지하면 재연결을 시작한다', () async {
      final h = _Harness(FakeAsync(), successScript: [true, true]);
      await h.connect();
      expect(h.statuses, [ConnectionStatus.initialConnected]);

      // 스트림은 살아있지만 소켓 상태만 닫힘 (ghost) → 60초 주기 heartbeat 가 감지
      h.sockets.first.readyStateValue = WebSocket.closed;
      await h.elapse(const Duration(seconds: 60));
      expect(h.statuses.last, ConnectionStatus.reconnecting);

      await h.elapse(const Duration(seconds: 3));
      expect(h.statuses.last, ConnectionStatus.reconnected);
      expect(h.attempts, 2);

      await h.dispose();
    });

    test('연결 성공 상태에서 같은 shopCode 로 connect 재호출은 무시된다', () async {
      final h = _Harness(FakeAsync(), successScript: [true]);
      await h.connect();
      expect(h.attempts, 1);

      await h.connect(); // 동일 정보 재호출
      expect(h.attempts, 1);
      expect(h.statuses, [ConnectionStatus.initialConnected]);

      await h.dispose();
    });
  });

  group('AppFitNotifierService disconnect / dispose', () {
    test('disconnect 는 disconnected 를 emit 하고 재연결을 중단한다', () async {
      final h = _Harness(FakeAsync(), successScript: [true]);
      await h.connect();

      await h.disconnect();
      expect(h.statuses, [
        ConnectionStatus.initialConnected,
        ConnectionStatus.disconnected,
      ]);
      expect(h.service.isConnected, false);
      expect(h.service.cachedShopCode, isNull);

      // 연결 정보가 비워져 네트워크 복원 신호도 무시된다
      h.fake.run((_) => h.service.notifyNetworkRestored());
      await h.elapse(const Duration(minutes: 10));
      expect(h.attempts, 1);

      await h.dispose();
    });

    test('disconnect 후 다시 connect 하면 initialConnected 부터 다시 시작한다', () async {
      final h = _Harness(FakeAsync(), successScript: [true, true]);
      await h.connect();
      await h.disconnect();

      await h.connect();
      expect(h.statuses, [
        ConnectionStatus.initialConnected,
        ConnectionStatus.disconnected,
        ConnectionStatus.initialConnected, // _hasEverConnected 가 리셋됨
      ]);

      await h.dispose();
    });

    test('dispose 이후 connect 는 무시된다', () async {
      final h = _Harness(FakeAsync(), successScript: [true]);
      await h.dispose();

      await h.connect();
      await h.elapse(const Duration(minutes: 1));
      expect(h.attempts, 0);
      expect(h.statuses, isEmpty);
    });

    test('연결 정보가 없으면 notifyNetworkRestored 는 무시된다', () async {
      final h = _Harness(FakeAsync(), successScript: [true]);
      h.fake.run((_) => h.service.notifyNetworkRestored()); // connect 이전
      await h.elapse(const Duration(minutes: 1));
      expect(h.attempts, 0);
      expect(h.statuses, isEmpty);
    });
  });

  group('AppFitNotifierService 연결 헤더', () {
    test('암호화된 Authorization + 프로젝트/매장 헤더로 연결을 시도한다', () async {
      final h = _Harness(FakeAsync(), successScript: [true]);
      await h.connect();

      final headers = h.lastHeaders!;
      expect(headers['X-Waldlust-ProjectId'], 'PRJ-001');
      expect(headers['X-Waldlust-ShopCode'], 'SHOP1');
      expect(headers['Authorization'], startsWith('Bearer '));
      // Bearer 토큰은 AES-GCM 암호문 — 원문 apiKey 가 그대로 노출되지 않는다
      expect(headers['Authorization'], isNot(contains('api-key')));

      await h.dispose();
    });
  });
}
