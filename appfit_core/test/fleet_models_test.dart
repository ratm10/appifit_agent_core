import 'package:flutter_test/flutter_test.dart';

import 'package:appfit_core/appfit_core.dart';

FleetDeviceInfo device({
  String storeId = 'MATA00001',
  String appVersion = '3.2.1',
  String? serial = 'H092W24A1G00862',
}) =>
    FleetDeviceInfo(
      deviceId: 'DE33256H10784',
      idSource: 'serial',
      serial: serial,
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

void main() {
  group('FleetDeviceInfo.fingerprint', () {
    test('매장이 바뀌면 지문이 달라진다 (재등록 발화 조건)', () {
      expect(
        device(storeId: 'MATA00001').fingerprint,
        isNot(device(storeId: 'PAIK00007').fingerprint),
      );
    });

    test('앱 버전이 바뀌면 지문이 달라진다 (버전 드리프트 추적)', () {
      expect(
        device(appVersion: '3.2.1').fingerprint,
        isNot(device(appVersion: '3.3.0').fingerprint),
      );
    });

    test('같은 정적 정보면 지문이 같다 — 매 틱 재등록하지 않는다', () {
      expect(device().fingerprint, device().fingerprint);
    });

    test('시리얼이 null 이어도 지문 계산이 깨지지 않는다', () {
      expect(device(serial: null).fingerprint, isNot(device().fingerprint));
    });
  });

  group('FleetDeviceInfo.toJson', () {
    test('와이어 필드명이 서버 계약과 일치한다', () {
      final json = device().toJson();
      expect(
        json.keys.toSet(),
        {
          'deviceId',
          'idSource',
          'serial',
          'appType',
          'storeId',
          'storeName',
          'appVersion',
          'buildNumber',
          'platform',
          'osVersion',
          'deviceModel',
          'deviceManufacturer',
          'environment',
        },
      );
      expect(json['deviceId'], 'DE33256H10784');
      expect(json['storeId'], 'MATA00001');
    });
  });

  group('FleetRuntime', () {
    const runtime = FleetRuntime(
      status: FleetStatus.online,
      lifecycle: 'resumed',
      socketConnected: true,
      mode: 'KDS',
      businessOpen: true,
      connection: 'wifi',
      commandRunning: true,
    );

    test('status 는 문자열로 직렬화된다', () {
      expect(runtime.toJson()['status'], 'online');
      expect(runtime.copyWith(status: FleetStatus.closing).toJson()['status'],
          'closing');
    });

    test('copyWith 는 status/commandRunning 만 바꾸고 나머지는 보존한다', () {
      final closing = runtime.copyWith(status: FleetStatus.closing);
      expect(closing.mode, 'KDS');
      expect(closing.lifecycle, 'resumed');
      expect(closing.businessOpen, isTrue);
      expect(closing.commandRunning, isTrue);
    });

    test('선택 필드는 null 을 그대로 실어 보낸다 (DID/KIOSK 에는 mode 가 없음)', () {
      const minimal = FleetRuntime(
        status: FleetStatus.online,
        lifecycle: 'resumed',
        socketConnected: false,
      );
      final json = minimal.toJson();
      expect(json['mode'], isNull);
      expect(json['businessOpen'], isNull);
      expect(json['commandRunning'], isFalse);
    });
  });

  group('FleetCommand.fromJson', () {
    test('정상 명령을 파싱한다', () {
      final c = FleetCommand.fromJson({
        'commandId': 'c-1',
        'type': 'LOG_UPLOAD_REQUESTED',
        'payload': {'fromDate': '2026-07-24', 'storeId': 'MATA00001'},
      });
      expect(c, isNotNull);
      expect(c!.commandId, 'c-1');
      expect(c.type, FleetCommandTypes.logUpload);
      expect(c.targetStoreId, 'MATA00001');
      expect(c.targetDeviceId, isNull);
    });

    test('commandId 나 type 이 없거나 비면 null 을 돌려준다', () {
      expect(FleetCommand.fromJson({'type': 'PING'}), isNull);
      expect(FleetCommand.fromJson({'commandId': 'c-1'}), isNull);
      expect(FleetCommand.fromJson({'commandId': '', 'type': 'PING'}), isNull);
      expect(FleetCommand.fromJson({'commandId': 'c-1', 'type': 123}), isNull);
    });

    test('payload 가 없거나 Map 이 아니면 빈 맵으로 둔다', () {
      expect(FleetCommand.fromJson({'commandId': 'c', 'type': 'PING'})!.payload,
          isEmpty);
      expect(
        FleetCommand.fromJson(
                {'commandId': 'c', 'type': 'PING', 'payload': 'x'})!
            .payload,
        isEmpty,
      );
    });
  });

  group('FleetAck.fromJson', () {
    test('모르는 키를 무시한다 — 서버가 먼저 배포돼도 구버전 앱이 안 깨진다', () {
      final ack = FleetAck.fromJson({
        'ok': true,
        'serverTimeMs': 1785400060000,
        'nextIntervalSeconds': 15,
        'commands': [],
        'someFutureField': {'nested': true},
        'anotherOne': 42,
      });
      expect(ack.success, isTrue);
      expect(ack.serverTimeMs, 1785400060000);
      expect(ack.nextIntervalSeconds, 15);
    });

    test('망가진 명령은 건너뛰고 정상 명령만 취한다', () {
      final ack = FleetAck.fromJson({
        'ok': true,
        'commands': [
          {'commandId': 'c-good', 'type': 'PING'},
          {'type': 'PING'}, // commandId 없음
          'not-a-map',
          {'commandId': 'c-good2', 'type': 'STATUS_REPORT_REQUESTED'},
        ],
      });
      expect(ack.commands.map((c) => c.commandId), ['c-good', 'c-good2']);
    });

    test('ok 가 false 면 실패로 읽고 error 를 보존한다', () {
      final ack = FleetAck.fromJson({'ok': false, 'error': 'unauthorized'});
      expect(ack.success, isFalse);
      expect(ack.error, 'unauthorized');
      expect(ack.permanent, isFalse, reason: 'permanent 는 와이어가 아니라 sink 가 채운다');
    });

    test('needsRegister 를 읽는다', () {
      expect(
          FleetAck.fromJson({'ok': true, 'needsRegister': true}).needsRegister,
          isTrue);
      expect(FleetAck.fromJson({'ok': true}).needsRegister, isFalse);
    });

    test('asPermanent() 는 내용을 보존하고 플래그만 세운다', () {
      final ack = FleetAck.fromJson({'ok': false, 'error': 'bad request'})
          .asPermanent();
      expect(ack.permanent, isTrue);
      expect(ack.error, 'bad request');
      expect(ack.success, isFalse);
    });
  });

  group('FleetCommandResult', () {
    test('명명 생성자가 코드와 성공 여부를 올바르게 세운다', () {
      expect(const FleetCommandResult.ok('c').code, FleetResultCodes.ok);
      expect(const FleetCommandResult.ok('c').success, isTrue);

      for (final r in [
        const FleetCommandResult.unsupported('c'),
        const FleetCommandResult.busy('c'),
        const FleetCommandResult.failed('c', 'e'),
        const FleetCommandResult.invalidTarget('c'),
      ]) {
        expect(r.success, isFalse, reason: '${r.code} 는 실패로 보고돼야 한다');
      }
    });

    test('toJson 이 서버 계약과 일치한다', () {
      final json = const FleetCommandResult.ok(
        'c-1',
        message: '3개 파일, 1.2 MB',
        reference: 'F09ABCDEF',
      ).toJson();
      expect(json, {
        'commandId': 'c-1',
        'success': true,
        'code': 'OK',
        'message': '3개 파일, 1.2 MB',
        'reference': 'F09ABCDEF',
      });
    });
  });
}
