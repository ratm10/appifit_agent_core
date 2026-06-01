import 'package:sentry_flutter/sentry_flutter.dart';

import '../http/api_http_exception.dart';
import '../logging/appfit_logger.dart';
import 'monitoring_service.dart';

/// AppFitLogger 구현체 - 기존 로거를 감싸고 오류만 Sentry에 전송
///
/// delegate 패턴: 기존 로거를 그대로 유지하면서 Sentry 오류 전송 추가.
/// - 일반 로그(`log`)는 Sentry에 전송하지 않음 (노이즈 방지)
/// - 오류(`error`)만 Sentry에 전송
///
/// [ApiHttpException] 이 전달되면 서버 code/message 를 태그·fingerprint 로
/// 구조화하고, "예상된" 비즈니스 오류는 issue 대신 breadcrumb 으로만 남긴다.
class SentryAppFitLogger implements AppFitLogger {
  final AppFitLogger delegate;

  SentryAppFitLogger({required this.delegate});

  /// issue 로 올리지 않고 breadcrumb(info) 으로만 남길 "예상된" 서버 코드.
  /// 유저 액션의 정상적 결과(중복 처리 등)이며 장애가 아니다.
  /// 새 코드 추가는 이 Set 한 줄로 토글한다.
  static const Set<String> benignServerCodes = {
    'INVALID_ORDER_STATUS', // 이미 픽업/완료/취소/수락된 주문 등
  };

  @override
  Future<void> log(String message) async {
    // 일반 로그는 기존 로거에만 기록 (Sentry breadcrumb 전송 안 함)
    await delegate.log(message);
  }

  @override
  Future<void> error(String message, dynamic error) async {
    await delegate.error(message, error);

    if (error is ApiHttpException) {
      final extras = error.toExtras();

      // 예상된 비즈니스 오류 → breadcrumb(info)만, issue 미전송.
      // 서버 메시지/코드는 그대로 보존되어 추적 시 컨텍스트로 보인다.
      if (error.code != null && benignServerCodes.contains(error.code)) {
        Sentry.addBreadcrumb(Breadcrumb(
          message: error.toString(),
          category: 'http',
          level: SentryLevel.info,
          data: extras,
        ));
        return;
      }

      MonitoringService.instance.captureError(
        error,
        error.cause.stackTrace,
        hint: message,
        extras: extras,
        fingerprint: error.fingerprint,
        cooldownKey: 'http:${error.status}:${error.path}',
      );
      return;
    }

    MonitoringService.instance.captureError(
      error ?? Exception(message),
      null,
      hint: message,
    );
  }
}
