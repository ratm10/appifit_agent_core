import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:appfit_core/src/logging/appfit_logger.dart';
import 'package:appfit_core/src/monitoring/monitoring_service.dart';
import 'package:appfit_core/src/socket/notifier_service.dart';

/// AppFit Notifier 서비스 Riverpod 래퍼 (공용)
///
/// 프로젝트별로 Logger만 주입하여 재사용합니다.
/// 재연결 로직은 AppFitNotifierService 내부에서 완전히 처리됩니다.
/// 앱 레이어는 connect() / disconnect() 만 호출합니다.
class AppFitNotifierNotifier extends Notifier<ConnectionStatus> {
  late final AppFitNotifierService _coreService;
  StreamSubscription<ConnectionStatus>? _connectionStateSubscription;

  final AppFitLogger _logger;

  AppFitNotifierNotifier({required AppFitLogger logger}) : _logger = logger;

  /// 연결된 매장 코드 (Getter)
  String? get cachedShopCode => _coreService.cachedShopCode;

  /// 주문 알림 스트림 (Getter)
  Stream<Map<String, dynamic>> get stream => _coreService.stream;

  @override
  ConnectionStatus build() {
    _coreService = AppFitNotifierService(logger: _logger);
    _connectionStateSubscription = _coreService.connectionStateStream.listen(
      (status) {
        state = status;
        MonitoringService.instance.onConnectionStatusChanged(status);
      },
    );
    // dispose 순서:
    // 1) 상태 스트림 구독 취소 → 이후 state 업데이트 방지
    // 2) core service dispose() → WebSocket 리스너·타이머 완전 정리 후 컨트롤러 close
    ref.onDispose(() async {
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      await _coreService.dispose();
    });
    return ConnectionStatus.disconnected;
  }

  Future<void> connect({
    required String shopCode,
    required String projectId,
    required String apiKey,
    required String aesKey,
  }) async =>
      _coreService.connect(
        shopCode: shopCode,
        projectId: projectId,
        apiKey: apiKey,
        aesKey: aesKey,
      );

  Future<void> disconnect() => _coreService.disconnect();

  /// 네트워크가 복원됐음을 앱이 직접 알린다 — 백오프를 초기화하고 즉시 재연결.
  ///
  /// 코어는 connectivity 인터페이스 변경 이벤트로 복원을 감지하지만, 링크는
  /// 살아 있고 상위 경로(DNS/라우팅)만 죽는 장애에서는 그 이벤트가 오지 않는다.
  /// 앱이 다른 경로로 복원을 확인했다면(예: HTTP 요청이 다시 성공) 이 메서드로
  /// 느린 재시도(5분 간격) 대기를 건너뛸 수 있다.
  ///
  /// 이미 연결됐거나 연결 시도 중이면, 또는 로그아웃 상태(연결 정보 없음)면
  /// 코어에서 무시되므로 호출측이 상태를 따로 검사할 필요는 없다.
  void notifyNetworkRestored() => _coreService.notifyNetworkRestored();
}
