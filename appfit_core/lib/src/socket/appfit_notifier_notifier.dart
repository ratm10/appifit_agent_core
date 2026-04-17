import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../auth/token_manager.dart';
import '../monitoring/monitoring_service.dart';
import 'notifier_service.dart';

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
}
