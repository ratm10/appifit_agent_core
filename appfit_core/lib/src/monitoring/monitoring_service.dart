import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../socket/notifier_service.dart';
import 'monitoring_context.dart';

/// Sentry 기반 모니터링 서비스 (싱글톤)
///
/// ## 보고 범위
/// 1. 앱 접속 정보 (매장/기기/앱 버전 태그)
/// 2. 소켓 상태 변화 Breadcrumb (중복 방지 처리됨)
/// 3. 치명적 오류 (unhandled exception, Flutter fatal error, 네이티브 크래시)
///
/// ## 중복/노이즈 방지
/// - 소켓 상태 전환 60초 쿨다운 (동일 전환 반복 시 이벤트 생략)
/// - 5분 윈도우 내 6회 이상 전환 시 Flapping 감지
///   → Flapping(플래핑): 네트워크 불안정으로 connected ↔ disconnected가
///     빠르게 반복되는 현상. 수십 개의 Breadcrumb이 쌓이는 것을 막기 위해
///     Flapping 상태 진입 시 경고 1건만 전송하고 개별 이벤트는 중단.
/// - captureError 동일 타입 5분 쿨다운
class MonitoringService {
  MonitoringService._();

  static final MonitoringService instance = MonitoringService._();

  bool _initialized = false;
  ConnectionStatus? _lastConnectionStatus;

  // --- 쿨다운 ---
  /// 상태 전환별 마지막 전송 시각 ("previous→current" 키)
  final Map<String, DateTime> _transitionCooldowns = {};

  /// 쿨다운 중 생략된 횟수
  final Map<String, int> _skippedCounts = {};

  static const Duration _transitionCooldown = Duration(seconds: 60);

  // --- Flapping ---
  // Flapping(플래핑): connected ↔ disconnected 상태가 짧은 시간에 반복되는 현상.
  // 5분 내 6회 이상 전환 시 Flapping으로 간주하고, 개별 이벤트 대신 경고 1건만 전송.
  final List<DateTime> _recentTransitions = [];
  bool _isFlapping = false;
  Timer? _flappingStabilityTimer;
  int _flappingTransitionCount = 0;

  static const int _flappingThreshold = 6;
  static const Duration _flappingWindow = Duration(minutes: 5);

  /// Flapping 안정화 판정 시간: 이 시간 동안 추가 전환이 없으면 Flapping 해제
  static const Duration _flappingStabilityDuration = Duration(minutes: 2);

  // --- Error rate limit ---
  final Map<String, DateTime> _errorCooldowns = {};

  /// 동일 오류 타입은 이 시간 내 재전송 안 함
  static const Duration _errorCooldown = Duration(minutes: 5);

  /// 초기화
  Future<void> init({
    required String dsn,
    required MonitoringContext context,
  }) async {
    if (_initialized) return;

    await SentryFlutter.init((options) {
      options.dsn = dsn;
      options.environment = context.environment;
      options.release =
          '${context.appType.toLowerCase()}@${context.appVersion}+${context.buildNumber}';

      // Sentry SDK 자체 디버그 로그 비활성화 (콘솔 노이즈 방지)
      options.debug = false;

      // 성능 트레이싱 비활성화 (불필요한 이벤트 제거)
      options.tracesSampleRate = 0.0;

      // 오류 발생 시 스택트레이스 항상 첨부
      options.attachStacktrace = true;

      // 세션 트래킹 비활성화 (단순 오류 모니터링만 사용)
      options.enableAutoSessionTracking = false;
    });

    _applyScope(context);
    _initialized = true;
  }

  /// 로그인 후 매장정보 업데이트 시 호출 (전체 컨텍스트 교체)
  void updateContext(MonitoringContext context) {
    _applyScope(context);
  }

  /// 매장 정보만 업데이트 (앱/기기 정보는 유지)
  void updateStoreInfo({required String storeId, required String storeName}) {
    if (!_initialized) return;
    Sentry.configureScope((scope) {
      scope.setUser(SentryUser(id: storeId, username: storeName));
      scope.setTag('store_id', storeId);
      scope.setContexts('store_info', {
        'store_id': storeId,
        'store_name': storeName,
      });
    });
  }

  /// 소켓 연결 상태 변경 이벤트
  ///
  /// 60초 쿨다운과 Flapping 감지로 중복 전송을 방지합니다.
  void onConnectionStatusChanged(ConnectionStatus status) {
    if (!_initialized) return;

    final previous = _lastConnectionStatus;
    _lastConnectionStatus = status;

    final transitionKey = '${previous?.name ?? "none"}→${status.name}';

    // flapping 전환 목록 갱신
    final now = DateTime.now();
    _recentTransitions.add(now);
    _recentTransitions.removeWhere(
      (t) => now.difference(t) > _flappingWindow,
    );

    // Flapping 진입 감지: 5분 내 6회 이상 전환 시
    if (!_isFlapping && _recentTransitions.length >= _flappingThreshold) {
      _isFlapping = true;
      _flappingTransitionCount = _recentTransitions.length;
      Sentry.captureMessage(
        'Network flapping detected (${_recentTransitions.length} transitions in 5min)',
        level: SentryLevel.warning,
      );
      _resetFlappingStabilityTimer();
      return; // flapping 진입 시 개별 이벤트 생략
    }

    if (_isFlapping) {
      // Flapping 상태에서 안정화 타이머 재시작 (추가 전환 발생 시)
      _resetFlappingStabilityTimer();
      return; // 개별 breadcrumb 전송 중단
    }

    // 60초 쿨다운 체크: 동일 전환은 60초 내 재전송 안 함
    final lastSent = _transitionCooldowns[transitionKey];
    if (lastSent != null && now.difference(lastSent) < _transitionCooldown) {
      _skippedCounts[transitionKey] = (_skippedCounts[transitionKey] ?? 0) + 1;
      return;
    }

    // 이전 생략 횟수 포함하여 전송
    final skipped = _skippedCounts[transitionKey] ?? 0;
    final message = skipped > 0
        ? 'Socket: $transitionKey ($skipped회 생략 후 전송)'
        : 'Socket: $transitionKey';

    _transitionCooldowns[transitionKey] = now;
    _skippedCounts[transitionKey] = 0;

    Sentry.addBreadcrumb(
      Breadcrumb(
        message: message,
        category: 'socket',
        level: status == ConnectionStatus.disconnected
            ? SentryLevel.warning
            : SentryLevel.info,
        data: {'status': status.name, 'previous': previous?.name ?? 'none'},
      ),
    );

    // 연결 상태 태그 업데이트
    Sentry.configureScope((scope) {
      scope.setTag('connection_status', status.name);
    });
  }

  /// 예외 캡처 (동일 타입 5분 쿨다운)
  ///
  /// 반복적인 동일 오류는 5분 내 1회만 전송합니다.
  void captureError(
    dynamic exception,
    StackTrace? stackTrace, {
    String? hint,
    Map<String, dynamic>? extras,
  }) {
    if (!_initialized) return;

    final typeKey = exception.runtimeType.toString();
    final now = DateTime.now();
    final lastSent = _errorCooldowns[typeKey];

    if (lastSent != null && now.difference(lastSent) < _errorCooldown) {
      // 쿨다운 중: breadcrumb으로만 기록 (Sentry 이벤트 미전송)
      Sentry.addBreadcrumb(
        Breadcrumb(
          message: '[Rate limited] $typeKey: $exception',
          category: 'error',
          level: SentryLevel.warning,
          data: extras,
        ),
      );
      return;
    }

    _errorCooldowns[typeKey] = now;
    Sentry.captureException(
      exception,
      stackTrace: stackTrace,
      hint: hint != null ? Hint.withMap({'hint': hint}) : null,
      withScope: extras != null
          ? (scope) {
              scope.setContexts('extras', extras);
            }
          : null,
    );
  }

  /// 리소스 해제 (앱 종료·로그아웃 시 호출).
  ///
  /// Flapping 타이머와 쿨다운 맵을 정리하고 초기화 플래그를 재설정해 `init()`을
  /// 다시 호출할 수 있게 합니다. `Sentry.close()` 는 호출하지 않으므로, 필요 시
  /// 소비자 앱이 별도로 호출하세요.
  Future<void> dispose() async {
    _flappingStabilityTimer?.cancel();
    _flappingStabilityTimer = null;
    _recentTransitions.clear();
    _transitionCooldowns.clear();
    _skippedCounts.clear();
    _errorCooldowns.clear();
    _lastConnectionStatus = null;
    _isFlapping = false;
    _flappingTransitionCount = 0;
    _initialized = false;
  }

  /// 테스트 전용: 싱글톤 내부 상태를 초기화.
  @visibleForTesting
  Future<void> resetForTesting() => dispose();

  // --- Private ---

  void _applyScope(MonitoringContext ctx) {
    Sentry.configureScope((scope) {
      scope.setUser(SentryUser(
        id: ctx.storeId.isNotEmpty ? ctx.storeId : null,
        username: ctx.storeName.isNotEmpty ? ctx.storeName : null,
      ));
      scope.setTag('app_type', ctx.appType);
      scope.setTag('environment', ctx.environment);
      if (ctx.storeId.isNotEmpty) scope.setTag('store_id', ctx.storeId);
      if (ctx.deviceManufacturer.isNotEmpty) {
        scope.setTag('device_manufacturer', ctx.deviceManufacturer);
      }
      scope.setContexts('app_info', {
        'version': ctx.appVersion,
        'build_number': ctx.buildNumber,
      });
      if (ctx.storeId.isNotEmpty) {
        scope.setContexts('store_info', {
          'store_id': ctx.storeId,
          'store_name': ctx.storeName,
        });
      }
      scope.setContexts('device_info', {
        'model': ctx.deviceModel,
        'manufacturer': ctx.deviceManufacturer,
      });
    });
  }

  void _resetFlappingStabilityTimer() {
    _flappingStabilityTimer?.cancel();
    _flappingStabilityTimer =
        Timer(_flappingStabilityDuration, _onFlappingStabilized);
  }

  void _onFlappingStabilized() {
    _isFlapping = false;
    Sentry.captureMessage(
      'Network flapping resolved (was $_flappingTransitionCount transitions in 5min)',
      level: SentryLevel.info,
    );
    _flappingTransitionCount = 0;
    _recentTransitions.clear();
  }
}
