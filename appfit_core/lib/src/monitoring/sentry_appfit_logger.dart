import '../auth/token_manager.dart';
import 'monitoring_service.dart';

/// AppFitLogger 구현체 - 기존 로거를 감싸고 오류만 Sentry에 전송
///
/// delegate 패턴: 기존 로거를 그대로 유지하면서 Sentry 오류 전송 추가.
/// - 일반 로그(`log`)는 Sentry에 전송하지 않음 (노이즈 방지)
/// - 오류(`error`)만 Sentry에 전송
class SentryAppFitLogger implements AppFitLogger {
  final AppFitLogger delegate;

  SentryAppFitLogger({required this.delegate});

  @override
  Future<void> log(String message) async {
    // 일반 로그는 기존 로거에만 기록 (Sentry breadcrumb 전송 안 함)
    await delegate.log(message);
  }

  @override
  Future<void> error(String message, dynamic error) async {
    await delegate.error(message, error);
    MonitoringService.instance.captureError(
      error ?? Exception(message),
      null,
      hint: message,
    );
  }
}
