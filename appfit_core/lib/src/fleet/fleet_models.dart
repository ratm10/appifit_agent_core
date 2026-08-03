// 기기 관제(Fleet) 와이어 모델. 서버(Cloudflare Worker)와의 register/heartbeat
// 계약을 담는다. 소비 앱(order_agent, did, kiosk)이 공통으로 사용한다.

/// 기기가 스스로 보고하는 실행 상태.
enum FleetStatus {
  /// 정상 동작 중.
  online,

  /// 종료 직전 best-effort 1회. `paused` 에서는 보내지 않는다 —
  /// Android 는 오버레이 버블 때문에 paused 가 상시 발생해서
  /// 대시보드가 "종료 중"으로 도배된다.
  closing,
}

extension FleetStatusWire on FleetStatus {
  String get value => this == FleetStatus.closing ? 'closing' : 'online';
}

/// 정적 기기 정보. 값이 바뀌면 재등록(register)이 발화한다.
///
/// [deviceId] 는 **반드시 소비 앱이 조달한다.** 이 모듈은 어떤 식별자도
/// 생성하거나 영속하지 않는다 — 정본이 둘로 갈라지는 걸 구조로 막기 위해서다.
/// order_agent 의 정본은 `DeviceIdentityService`(시리얼 > MachineGuid > 설치 UUID).
class FleetDeviceInfo {
  final String deviceId;

  /// [deviceId] 의 출처. serial | deviceId | installId
  final String idSource;
  final String? serial;

  /// ORDER_AGENT | DID | KIOSK
  final String appType;

  /// 로그인 전에는 빈 문자열. 서버가 "미배정" 버킷으로 분류한다.
  final String storeId;
  final String storeName;

  final String appVersion;
  final String buildNumber;

  /// android | windows | ios
  final String platform;
  final String osVersion;
  final String deviceModel;
  final String deviceManufacturer;

  /// live | japanLive | staging | dev
  final String environment;

  const FleetDeviceInfo({
    required this.deviceId,
    required this.idSource,
    required this.serial,
    required this.appType,
    required this.storeId,
    required this.storeName,
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.osVersion,
    required this.deviceModel,
    required this.deviceManufacturer,
    required this.environment,
  });

  /// 재등록 판정용 지문. 전 필드를 이어붙인 문자열 비교라서
  /// [DateTime.now] 같은 시계 의존이 없고 fakeAsync 로 검증된다.
  ///
  /// 영속하지 않으므로 콜드 스타트마다 register 가 1회 발화하고, 서버는 그걸
  /// boot_count 로 세어 크래시 루프를 드러낸다.
  String get fingerprint => [
        deviceId,
        idSource,
        serial ?? '',
        appType,
        storeId,
        storeName,
        appVersion,
        buildNumber,
        platform,
        osVersion,
        deviceModel,
        deviceManufacturer,
        environment,
      ].join('|');

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'idSource': idSource,
        'serial': serial,
        'appType': appType,
        'storeId': storeId,
        'storeName': storeName,
        'appVersion': appVersion,
        'buildNumber': buildNumber,
        'platform': platform,
        'osVersion': osVersion,
        'deviceModel': deviceModel,
        'deviceManufacturer': deviceManufacturer,
        'environment': environment,
      };

  @override
  String toString() => 'FleetDeviceInfo($appType/$deviceId, store=$storeId)';
}

/// 동적 상태. heartbeat 마다 새로 만든다.
class FleetRuntime {
  final FleetStatus status;

  /// resumed | inactive | paused | hidden | detached.
  /// 대시보드가 "백그라운드"와 "무응답"을 구분하는 근거 — Android Doze 가
  /// 타이머를 늘려도 앱이 살아있다는 걸 보여준다.
  final String lifecycle;
  final bool socketConnected;

  /// MAIN | KDS. DID/KIOSK 는 null.
  final String? mode;
  final bool? businessOpen;

  /// wifi | ethernet | mobile | none
  final String? connection;

  /// 장시간 명령(로그 zip)이 진행 중인지.
  final bool commandRunning;

  const FleetRuntime({
    required this.status,
    required this.lifecycle,
    required this.socketConnected,
    this.mode,
    this.businessOpen,
    this.connection,
    this.commandRunning = false,
  });

  FleetRuntime copyWith({FleetStatus? status, bool? commandRunning}) =>
      FleetRuntime(
        status: status ?? this.status,
        lifecycle: lifecycle,
        socketConnected: socketConnected,
        mode: mode,
        businessOpen: businessOpen,
        connection: connection,
        commandRunning: commandRunning ?? this.commandRunning,
      );

  Map<String, dynamic> toJson() => {
        'status': status.value,
        'lifecycle': lifecycle,
        'socketConnected': socketConnected,
        'mode': mode,
        'businessOpen': businessOpen,
        'connection': connection,
        'commandRunning': commandRunning,
      };
}

class FleetSnapshot {
  final FleetDeviceInfo device;
  final FleetRuntime runtime;

  const FleetSnapshot({required this.device, required this.runtime});
}

/// 서버 → 기기 명령.
///
/// [type] 이 enum 이 아니라 String 인 것은 의도적이다. enum 이면 새 명령 타입을
/// 추가할 때마다 core 재릴리즈 + 앱 ref 범프가 강제된다. 리포터는 절대
/// type 으로 분기하지 않고 앱 핸들러에 그대로 넘긴다.
class FleetCommand {
  final String commandId;
  final String type;
  final Map<String, dynamic> payload;

  const FleetCommand({
    required this.commandId,
    required this.type,
    this.payload = const {},
  });

  static FleetCommand? fromJson(Map<String, dynamic> json) {
    final id = json['commandId'];
    final type = json['type'];
    if (id is! String || id.isEmpty || type is! String || type.isEmpty) {
      return null;
    }
    final raw = json['payload'];
    return FleetCommand(
      commandId: id,
      type: type,
      payload: raw is Map ? Map<String, dynamic>.from(raw) : const {},
    );
  }

  /// 명령이 지정한 대상 기기. 없으면 null(대상 무관).
  String? get targetDeviceId {
    final v = payload['deviceId'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 명령이 지정한 대상 매장. 없으면 null.
  String? get targetStoreId {
    final v = payload['storeId'];
    return v is String && v.isNotEmpty ? v : null;
  }

  @override
  String toString() => 'FleetCommand($type, $commandId)';
}

/// 명령 타입 상수. **편의 제공일 뿐** 리포터는 이 값으로 분기하지 않는다.
class FleetCommandTypes {
  FleetCommandTypes._();

  static const String logUpload = 'LOG_UPLOAD_REQUESTED';
  static const String statusReport = 'STATUS_REPORT_REQUESTED';
  static const String ping = 'PING';
}

class FleetResultCodes {
  FleetResultCodes._();

  static const String ok = 'OK';

  /// 이 앱이 지원하지 않는 명령. 로그 수집이 없는 DID 등.
  static const String unsupported = 'UNSUPPORTED';

  /// 다른 명령이 실행 중.
  static const String busy = 'BUSY';
  static const String failed = 'FAILED';

  /// 대상 기기/매장이 현재 상태와 불일치. 매장 전환 직후 구 바인딩 명령 차단.
  static const String invalidTarget = 'INVALID_TARGET';
}

class FleetCommandResult {
  final String commandId;
  final bool success;
  final String code;
  final String? message;

  /// 외부 참조(Slack file_id 등).
  final String? reference;

  const FleetCommandResult({
    required this.commandId,
    required this.success,
    required this.code,
    this.message,
    this.reference,
  });

  const FleetCommandResult.ok(this.commandId, {this.message, this.reference})
      : success = true,
        code = FleetResultCodes.ok;

  const FleetCommandResult.unsupported(this.commandId, {this.message})
      : success = false,
        code = FleetResultCodes.unsupported,
        reference = null;

  const FleetCommandResult.busy(this.commandId, {this.message})
      : success = false,
        code = FleetResultCodes.busy,
        reference = null;

  const FleetCommandResult.failed(this.commandId, this.message)
      : success = false,
        code = FleetResultCodes.failed,
        reference = null;

  const FleetCommandResult.invalidTarget(this.commandId, {this.message})
      : success = false,
        code = FleetResultCodes.invalidTarget,
        reference = null;

  Map<String, dynamic> toJson() => {
        'commandId': commandId,
        'success': success,
        'code': code,
        'message': message,
        'reference': reference,
      };

  @override
  String toString() => 'FleetCommandResult($commandId, $code)';
}

/// register / heartbeat 공통 응답.
class FleetAck {
  final bool success;
  final String? error;
  final List<FleetCommand> commands;

  /// 서버 시각. 시계 오차 진단에만 쓰고 보정하지 않는다.
  final int? serverTimeMs;

  /// 서버가 지시하는 다음 폴링 간격(초). 리포터가 [15,600] 으로 클램프한다.
  final int? nextIntervalSeconds;

  /// 서버가 이 기기를 모른다. 다음 틱에 register 해야 한다.
  final bool needsRegister;

  /// 예약 — per-device 토큰 전환 대비. 현재 항상 null.
  final String? deviceToken;

  /// 재시도해도 고쳐지지 않는 실패(계약 위반·인증 오류 등).
  /// **와이어 필드가 아니라 sink 가 채우는 클라이언트 전용 판단값**이다.
  /// 리포터는 이걸 보고 점진적 백오프 대신 곧바로 상한으로 간다.
  final bool permanent;

  const FleetAck({
    required this.success,
    this.error,
    this.commands = const [],
    this.serverTimeMs,
    this.nextIntervalSeconds,
    this.needsRegister = false,
    this.deviceToken,
    this.permanent = false,
  });

  const FleetAck.fail(this.error, {this.permanent = false})
      : success = false,
        commands = const [],
        serverTimeMs = null,
        nextIntervalSeconds = null,
        needsRegister = false,
        deviceToken = null;

  /// 모르는 키는 조용히 무시한다. 서버가 먼저 배포돼도 구버전 앱이 깨지지 않게.
  factory FleetAck.fromJson(Map<String, dynamic> json) {
    final rawCommands = json['commands'];
    final commands = <FleetCommand>[];
    if (rawCommands is List) {
      for (final item in rawCommands) {
        if (item is Map) {
          final c = FleetCommand.fromJson(Map<String, dynamic>.from(item));
          if (c != null) commands.add(c);
        }
      }
    }
    return FleetAck(
      success: json['ok'] == true,
      error: json['error'] is String ? json['error'] as String : null,
      commands: commands,
      serverTimeMs: json['serverTimeMs'] is num
          ? (json['serverTimeMs'] as num).toInt()
          : null,
      nextIntervalSeconds: json['nextIntervalSeconds'] is num
          ? (json['nextIntervalSeconds'] as num).toInt()
          : null,
      needsRegister: json['needsRegister'] == true,
      deviceToken:
          json['deviceToken'] is String ? json['deviceToken'] as String : null,
    );
  }

  /// 같은 내용에 [permanent] 만 세운 사본. sink 가 4xx 응답을 표시할 때 쓴다.
  FleetAck asPermanent() => FleetAck(
        success: success,
        error: error,
        commands: commands,
        serverTimeMs: serverTimeMs,
        nextIntervalSeconds: nextIntervalSeconds,
        needsRegister: needsRegister,
        deviceToken: deviceToken,
        permanent: true,
      );

  @override
  String toString() =>
      'FleetAck(ok=$success, commands=${commands.length}, next=$nextIntervalSeconds'
      '${needsRegister ? ', needsRegister' : ''}${error != null ? ', error=$error' : ''})';
}
