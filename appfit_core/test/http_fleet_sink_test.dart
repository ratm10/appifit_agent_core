import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

/// Dio 를 통째로 대체하지 않고 어댑터만 갈아끼운다. 그래야 sink 가 세운
/// validateStatus·인증 헤더·타임아웃을 실제로 거친 결과를 검증하게 된다.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.respond);

  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

const _device = FleetDeviceInfo(
  deviceId: 'DE33256H10784',
  idSource: 'serial',
  serial: 'DE33256H10784',
  appType: 'ORDER_AGENT',
  storeId: 'MATA00001',
  storeName: '마타 강남점',
  appVersion: '3.2.1',
  buildNumber: '412',
  platform: 'android',
  osVersion: '13',
  deviceModel: 'SUNMI D3 MINI',
  deviceManufacturer: 'SUNMI',
  environment: 'live',
);

const _snapshot = FleetSnapshot(
  device: _device,
  runtime: FleetRuntime(
    status: FleetStatus.online,
    lifecycle: 'resumed',
    socketConnected: true,
    mode: 'MAIN',
    businessOpen: true,
    connection: 'wifi',
  ),
);

HttpFleetSink _sink(_FakeAdapter adapter, {DateTime Function()? now}) =>
    HttpFleetSink(
      baseUrl: 'https://fleet.example.workers.dev',
      deviceKey: 'test-key',
      adapter: adapter,
      now: now,
    );

void main() {
  test('설정이 비면 isConfigured=false 이고 전송하지 않는다', () async {
    final adapter = _FakeAdapter((_) => _json({'ok': true}, 200));
    final sink = HttpFleetSink(baseUrl: '', deviceKey: '', adapter: adapter);

    expect(sink.isConfigured, isFalse);
    final ack = await sink.register(_device);
    expect(ack.success, isFalse);
    expect(adapter.requests, isEmpty, reason: '설정 없는데 네트워크를 때리면 안 된다');
  });

  test('register 는 정적 정보 전체와 reportedAt 을 보내고 Bearer 를 붙인다', () async {
    final adapter = _FakeAdapter((_) => _json({'ok': true}, 200));
    final sink = _sink(adapter, now: () => DateTime.utc(2026, 7, 30, 9));

    await sink.register(_device);

    final req = adapter.requests.single;
    expect(req.path, '/v1/device/register');
    expect(req.headers['Authorization'], 'Bearer test-key');

    final body = req.data as Map<String, dynamic>;
    expect(body['deviceId'], 'DE33256H10784');
    expect(body['storeId'], 'MATA00001');
    expect(body['osVersion'], '13');
    expect(body['reportedAt'], '2026-07-30T09:00:00.000Z');
  });

  test('heartbeat 는 동적 상태 + 결과 배열을 보낸다', () async {
    final adapter = _FakeAdapter((_) => _json({'ok': true}, 200));
    final sink = _sink(adapter, now: () => DateTime.utc(2026, 7, 30, 9, 1));

    await sink.heartbeat(_snapshot, const [
      FleetCommandResult.ok('c-1', message: '3개 파일', reference: 'F09'),
    ]);

    final body = adapter.requests.single.data as Map<String, dynamic>;
    expect(adapter.requests.single.path, '/v1/device/heartbeat');
    expect(body['status'], 'online');
    expect(body['lifecycle'], 'resumed');
    expect(body['socketConnected'], isTrue);
    expect(body['mode'], 'MAIN');
    expect(body['appVersion'], '3.2.1');
    expect(body['reportedAt'], '2026-07-30T09:01:00.000Z');

    final results = body['results'] as List;
    expect(results.single, {
      'commandId': 'c-1',
      'success': true,
      'code': 'OK',
      'message': '3개 파일',
      'reference': 'F09',
    });
  });

  test('200 응답의 명령 배열을 파싱한다', () async {
    final adapter = _FakeAdapter((_) => _json({
          'ok': true,
          'nextIntervalSeconds': 15,
          'commands': [
            {
              'commandId': 'c-9',
              'type': 'LOG_UPLOAD_REQUESTED',
              'payload': {'fromDate': '2026-07-24', 'toDate': '2026-07-30'},
            },
          ],
        }, 200));

    final ack = await _sink(adapter).heartbeat(_snapshot, const []);

    expect(ack.success, isTrue);
    expect(ack.nextIntervalSeconds, 15);
    expect(ack.commands.single.commandId, 'c-9');
    expect(ack.commands.single.payload['fromDate'], '2026-07-24');
  });

  test('4xx 는 예외가 아니라 permanent 실패로 바뀐다 (예외 폭주 방지)', () async {
    final adapter =
        _FakeAdapter((_) => _json({'ok': false, 'error': 'unauthorized'}, 401));

    final ack = await _sink(adapter).heartbeat(_snapshot, const []);

    expect(ack.success, isFalse);
    expect(ack.error, 'unauthorized');
    expect(ack.permanent, isTrue, reason: '키가 틀렸으면 재시도해도 안 고쳐진다');
  });

  test('429 는 4xx 지만 재시도 대상이라 permanent 가 아니다', () async {
    final adapter = _FakeAdapter(
        (_) => _json({'ok': false, 'error': 'too many requests'}, 429));

    final ack = await _sink(adapter).heartbeat(_snapshot, const []);

    expect(ack.success, isFalse);
    expect(ack.permanent, isFalse);
  });

  test('5xx 는 예외로 잡아 일시적 실패로 돌려준다', () async {
    final adapter = _FakeAdapter((_) => _json({'error': 'boom'}, 503));

    final ack = await _sink(adapter).heartbeat(_snapshot, const []);

    expect(ack.success, isFalse);
    expect(ack.error, contains('503'));
    expect(ack.permanent, isFalse);
  });

  test('네트워크 오류에서도 예외를 던지지 않는다 — 관제가 앱을 막으면 안 된다', () async {
    final adapter = _FakeAdapter((options) {
      throw DioException.connectionTimeout(
        timeout: const Duration(seconds: 10),
        requestOptions: options,
      );
    });

    final ack = await _sink(adapter).heartbeat(_snapshot, const []);

    expect(ack.success, isFalse);
    expect(ack.permanent, isFalse);
  });

  test('JSON 이 아닌 응답도 실패로 흡수한다', () async {
    final adapter = _FakeAdapter(
        (_) => ResponseBody.fromString('<html>maintenance</html>', 200));

    final ack = await _sink(adapter).heartbeat(_snapshot, const []);

    expect(ack.success, isFalse);
  });
}
