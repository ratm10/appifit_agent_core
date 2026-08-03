import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

/// 실제 Worker 를 상대로 하는 왕복 계약 검증.
///
/// **왜 필요한가**: 앱 쪽 단위 테스트(http_fleet_sink_test)와 서버 쪽
/// 스모크 테스트(appfit-fleet/test/smoke.sh)는 각각 *자기가 가정한* JSON 을
/// 검증한다. 필드명이 어긋나 있어도 둘 다 초록으로 통과한다. 그 구멍을 막으려면
/// 진짜 Dart 클라이언트가 진짜 서버에 붙어야 한다.
///
/// 실행:
///   1) appfit-fleet 레포에서 `npm run dev`
///   2) flutter test test/fleet_live_roundtrip_test.dart
///
/// 서버가 떠 있지 않으면 각 테스트가 이유를 남기고 스킵한다. 설정 파일로
/// 막지 않는 이유는, 서버가 도는 개발 환경에서는 일반 `flutter test` 만으로도
/// 계약이 자동 검증되는 편이 낫기 때문이다.
const String baseUrl = 'http://localhost:8787';
const String deviceKey = 'dev-device-key';
const String adminPassword = 'dev-admin-pw';

FleetDeviceInfo deviceInfo(String deviceId) => FleetDeviceInfo(
      deviceId: deviceId,
      idSource: 'serial',
      serial: deviceId,
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

FleetSnapshot snapshotOf(FleetDeviceInfo device) => FleetSnapshot(
      device: device,
      runtime: const FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: true,
        mode: 'MAIN',
        businessOpen: true,
        connection: 'wifi',
      ),
    );

void main() {
  late Dio admin;
  late String cookie;
  late String deviceId;
  late HttpFleetSink sink;
  var serverUp = false;

  /// 서버가 없으면 실패가 아니라 스킵. 개발 머신에 Worker 가 떠 있을 때만
  /// 계약이 검증되고, 없으면 이유를 남기고 조용히 넘어간다.
  bool requireServer() {
    if (!serverUp) {
      markTestSkipped(
          '로컬 Worker($baseUrl) 미기동 — appfit-fleet 에서 `npm run dev` 후 재실행');
      return false;
    }
    return true;
  }

  setUpAll(() async {
    admin = Dio(BaseOptions(
      baseUrl: baseUrl,
      validateStatus: (s) => s != null && s < 500,
      connectTimeout: const Duration(seconds: 3),
      receiveTimeout: const Duration(seconds: 5),
    ));

    try {
      await admin.get<dynamic>('/');
      serverUp = true;
    } on DioException {
      return; // 각 테스트가 requireServer() 로 스킵한다.
    }

    final login = await admin.post<dynamic>(
      '/api/login',
      data: {'password': adminPassword},
    );
    final setCookie = login.headers.map['set-cookie']?.first ?? '';
    cookie = setCookie.split(';').first;
    expect(cookie, isNotEmpty, reason: '대시보드 로그인 실패');

    deviceId = 'LIVE-${DateTime.now().millisecondsSinceEpoch}';
    sink = HttpFleetSink(baseUrl: baseUrl, deviceKey: deviceKey);
  });

  Future<Map<String, dynamic>?> fetchDevice() async {
    final res = await admin.get<dynamic>(
      '/api/devices',
      options: Options(headers: {'Cookie': cookie}),
    );
    final devices = (res.data as Map)['devices'] as List;
    for (final d in devices) {
      if ((d as Map)['device_id'] == deviceId) {
        return Map<String, dynamic>.from(d);
      }
    }
    return null;
  }

  test('register → 서버가 정적 정보를 그대로 받아 저장한다', () async {
    if (!requireServer()) return;
    final ack = await sink.register(deviceInfo(deviceId));

    expect(ack.success, isTrue, reason: 'register 실패: ${ack.error}');
    expect(ack.serverTimeMs, isNotNull);

    final row = await fetchDevice();
    expect(row, isNotNull, reason: '대시보드 목록에 기기가 없다');

    // 필드가 하나라도 어긋나면 여기서 잡힌다 — Dart 의 camelCase 와
    // D1 의 snake_case 매핑이 서버 핸들러에서 올바른지 검증하는 지점.
    expect(row!['app_type'], 'ORDER_AGENT');
    expect(row['store_id'], 'MATA00001');
    expect(row['store_name'], '마타 강남점');
    expect(row['device_model'], 'SUNMI D3 MINI');
    expect(row['device_manufacturer'], 'SUNMI');
    expect(row['os_version'], '13');
    expect(row['platform'], 'android');
    expect(row['app_version'], '3.2.1');
    expect(row['build_number'], '412');
    expect(row['id_source'], 'serial');
    expect(row['environment'], 'live');
    expect(row['liveness'], 'online');
    expect(row['boot_count'], 1);
  });

  test('heartbeat → 동적 상태가 반영된다', () async {
    if (!requireServer()) return;
    await Future<void>.delayed(const Duration(seconds: 4)); // rate limit 회피
    final ack =
        await sink.heartbeat(snapshotOf(deviceInfo(deviceId)), const []);

    expect(ack.success, isTrue, reason: 'heartbeat 실패: ${ack.error}');
    expect(ack.nextIntervalSeconds, 60, reason: '대기 명령이 없으면 60초');

    final row = await fetchDevice();
    expect(row!['last_status'], 'online');
    expect(row['last_lifecycle'], 'resumed');
    expect(row['socket_connected'], 1);
    expect(row['mode'], 'MAIN');
    expect(row['business_open'], 1);
    expect(row['connection'], 'wifi');
  });

  test('대시보드가 건 명령이 heartbeat 응답에 실려 오고 결과가 반영된다', () async {
    if (!requireServer()) return;
    // 대시보드에서 로그 요청을 건다.
    final created = await admin.post<dynamic>(
      '/api/commands',
      data: {
        'appType': 'ORDER_AGENT',
        'deviceId': deviceId,
        'type': 'LOG_UPLOAD_REQUESTED',
        'payload': {'fromDate': '2026-07-24', 'toDate': '2026-07-30'},
      },
      options: Options(headers: {'Cookie': cookie}),
    );
    final commandId = (created.data as Map)['commandId'] as String;
    expect(commandId, isNotEmpty);

    // 기기가 다음 heartbeat 에서 받는다.
    await Future<void>.delayed(const Duration(seconds: 4));
    final ack =
        await sink.heartbeat(snapshotOf(deviceInfo(deviceId)), const []);

    expect(ack.commands, hasLength(1));
    final command = ack.commands.single;
    expect(command.commandId, commandId);
    expect(command.type, FleetCommandTypes.logUpload);
    expect(command.payload['fromDate'], '2026-07-24');
    // 서버가 타겟을 에코해야 클라이언트가 INVALID_TARGET 검증을 할 수 있다.
    expect(command.targetDeviceId, deviceId);
    expect(command.targetStoreId, 'MATA00001');
    expect(ack.nextIntervalSeconds, 15, reason: '실행 중 명령이 있으면 15초');

    // 실행 결과를 다음 heartbeat body 에 실어 보낸다.
    await Future<void>.delayed(const Duration(seconds: 4));
    final done = await sink.heartbeat(snapshotOf(deviceInfo(deviceId)), [
      FleetCommandResult.ok(
        commandId,
        message: '3개 파일, 1.2 MB',
        reference: 'F09ABCDEF',
      ),
    ]);
    expect(done.success, isTrue);
    expect(done.nextIntervalSeconds, 60, reason: '명령이 끝나면 60초로 복귀');

    // 대시보드에서 결과가 보인다.
    final list = await admin.get<dynamic>(
      '/api/commands?appType=ORDER_AGENT&deviceId=$deviceId&limit=5',
      options: Options(headers: {'Cookie': cookie}),
    );
    final commands = (list.data as Map)['commands'] as List;
    final row =
        commands.firstWhere((c) => (c as Map)['id'] == commandId) as Map;
    expect(row['status'], 'done');
    expect(row['result_code'], 'OK');
    expect(row['result_message'], '3개 파일, 1.2 MB');
    expect(row['result_reference'], 'F09ABCDEF');
  });

  test('알 수 없는 기기의 heartbeat 는 needsRegister 로 자가 치유된다', () async {
    if (!requireServer()) return;
    final ack = await sink.heartbeat(
      snapshotOf(deviceInfo('NEVER-REGISTERED-${DateTime.now().microsecond}')),
      const [],
    );
    expect(ack.success, isTrue, reason: '실패로 답하면 클라이언트가 백오프에 들어간다');
    expect(ack.needsRegister, isTrue);
  });

  test('잘못된 기기 키는 거부된다', () async {
    if (!requireServer()) return;
    final bad = HttpFleetSink(baseUrl: baseUrl, deviceKey: 'wrong-key');
    final ack = await bad.register(deviceInfo(deviceId));
    expect(ack.success, isFalse);
    expect(ack.permanent, isTrue, reason: '401 은 재시도해도 안 고쳐지므로 즉시 백오프 상한');
  });
}
