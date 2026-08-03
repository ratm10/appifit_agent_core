import 'package:dio/dio.dart';

import 'package:appfit_core/src/fleet/fleet_models.dart';
import 'package:appfit_core/src/fleet/fleet_sink.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// 관제 서버(Cloudflare Worker)로 보고를 보내는 sink.
///
/// **`appFitDioProvider` 의 Dio 를 재사용하면 안 된다.** 그 인스턴스는 baseUrl 이
/// AppFit core-api 이고 인터셉터가 매장 토큰과 `Waldlust-Project-ID` 를 자동
/// 주입한다 — 재사용하면 매장 자격증명이 관제 서버로 흘러간다. slack.com 에
/// 대해 `SlackDirectSink` 가 별도 클라이언트를 쓰는 것과 같은 이유다.
class HttpFleetSink implements FleetSink {
  static const String _registerPath = '/v1/device/register';
  static const String _heartbeatPath = '/v1/device/heartbeat';

  final String _baseUrl;
  final String _deviceKey;
  final AppFitLogger? _logger;
  final DateTime Function() _now;
  final Dio _dio;

  HttpFleetSink({
    required String baseUrl,
    required String deviceKey,
    AppFitLogger? logger,

    /// 테스트 주입점. Dio 를 통째로 받지 않는 이유는, 그러면 아래 BaseOptions
    /// (validateStatus·인증 헤더·타임아웃)가 테스트에서 우회되어 정작 검증하고
    /// 싶은 동작이 빠지기 때문이다. 어댑터만 갈아끼워 실제 설정을 거치게 한다.
    HttpClientAdapter? adapter,

    /// 인터벌(60초)보다 짧아야 한다. core 기본값 30초를 쓰면 응답이 느릴 때
    /// 틱이 밀려 케이던스가 무너진다.
    Duration timeout = const Duration(seconds: 10),

    /// `reportedAt` 스탬프 전용 주입점. 이 값은 서버의 어떤 판정에도 쓰이지
    /// 않는다(liveness 는 서버 수신 시각 기준).
    DateTime Function()? now,
  })  : _baseUrl = baseUrl,
        _deviceKey = deviceKey,
        _logger = logger,
        _now = now ?? DateTime.now,
        _dio = Dio(BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: timeout,
          receiveTimeout: timeout,
          sendTimeout: timeout,
          headers: {
            'Authorization': 'Bearer $deviceKey',
            'Content-Type': 'application/json',
          },
          // 4xx 를 예외로 만들지 않고 본문을 그대로 파싱해 FleetAck.fail 로
          // 바꾼다. 계약 위반이 예외 폭주로 번지지 않게 하기 위함.
          validateStatus: (status) => status != null && status < 500,
        )) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  @override
  String get name => 'HttpFleet';

  @override
  bool get isConfigured => _baseUrl.isNotEmpty && _deviceKey.isNotEmpty;

  String get _reportedAt => _now().toUtc().toIso8601String();

  @override
  Future<FleetAck> register(FleetDeviceInfo device) {
    return _post(_registerPath, {
      ...device.toJson(),
      'reportedAt': _reportedAt,
    });
  }

  @override
  Future<FleetAck> heartbeat(
    FleetSnapshot snapshot,
    List<FleetCommandResult> results,
  ) {
    final d = snapshot.device;
    return _post(_heartbeatPath, {
      'deviceId': d.deviceId,
      'appType': d.appType,
      'storeId': d.storeId,
      'storeName': d.storeName,
      'appVersion': d.appVersion,
      ...snapshot.runtime.toJson(),
      'reportedAt': _reportedAt,
      'results': results.map((r) => r.toJson()).toList(),
    });
  }

  /// 재시도해도 고쳐지지 않는 상태코드인가.
  /// 408(타임아웃)·429(레이트리밋)는 4xx 지만 재시도 대상이라 제외한다.
  static bool _isPermanent(int? status) =>
      status != null &&
      status >= 400 &&
      status < 500 &&
      status != 408 &&
      status != 429;

  Future<FleetAck> _post(String path, Map<String, dynamic> body) async {
    if (!isConfigured) return const FleetAck.fail('fleet 설정 없음');
    try {
      final res = await _dio.post<dynamic>(path, data: body);
      final data = res.data;
      if (data is Map) {
        final parsed = FleetAck.fromJson(Map<String, dynamic>.from(data));
        if (!parsed.success && _isPermanent(res.statusCode)) {
          _logger?.warn(
              '[Fleet] $path 계약 위반 HTTP ${res.statusCode}: ${parsed.error}');
          return parsed.asPermanent();
        }
        return parsed;
      }
      return FleetAck.fail(
        '예상치 못한 응답(${res.statusCode})',
        permanent: _isPermanent(res.statusCode),
      );
    } on DioException catch (e) {
      // 관제는 앱 동작에 영향을 주면 안 된다. 여기서 예외를 밖으로 내보내지
      // 않고 실패 ack 로 바꿔 리포터가 백오프만 하게 한다.
      final status = e.response?.statusCode;
      final detail = status != null ? 'HTTP $status' : e.type.name;
      _logger?.warn('[Fleet] $path 실패: $detail');
      return FleetAck.fail(detail, permanent: _isPermanent(status));
    } catch (e) {
      _logger?.warn('[Fleet] $path 실패: $e');
      return FleetAck.fail('$e');
    }
  }
}
