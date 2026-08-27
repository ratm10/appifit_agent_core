import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:appfit_core/src/http/api_http_exception.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';
import 'package:appfit_core/src/monitoring/monitoring_service.dart';

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

  /// **엔드포인트 단위**로 좁힌 benign 판정. 키는 템플릿 경로
  /// ([ApiHttpException.path]), 값은 그 경로에서만 양성으로 볼 서버 코드.
  ///
  /// `INVALID_REQUEST` 같은 범용 검증 코드를 [benignServerCodes] 에 넣으면
  /// **우리가 잘못된 본문을 보낸 진짜 결함까지 통째로 묻힌다.** 그래서 "사용자가
  /// 입력한 값이 틀렸을 뿐"이라고 단정할 수 있는 경로에서만 허용한다.
  static const Map<String, Set<String>> benignServerCodesByPath = {
    // 쿠폰 사용: 운영자가 입력란에 쿠폰번호 대신 전화번호를 넣거나 오타를 낸
    // 경우다. 멤버십 화면은 입력란 하나를 [회원조회]와 [쿠폰사용]이 공유해서
    // 구조적으로 재발한다. 앱이 입력을 걸러도(전화번호 패턴 차단) 단순 오타는
    // 남으므로, 이 경로의 검증 실패는 issue 가 아니라 breadcrumb 이 맞다.
    '/v0/coupon/{id}/use-without-item': {'INVALID_REQUEST'},
  };

  /// issue 대신 breadcrumb 으로만 남길 오류인지.
  static bool isBenign(ApiHttpException error) {
    final code = error.code;
    if (code == null) return false;
    if (benignServerCodes.contains(code)) return true;
    return benignServerCodesByPath[error.path]?.contains(code) ?? false;
  }

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
      if (isBenign(error)) {
        Sentry.addBreadcrumb(Breadcrumb(
          message: error.toString(),
          category: 'http',
          level: SentryLevel.info,
          data: extras,
        ));
        return;
      }

      // 서버 응답 없는 일시적 네트워크 오류(HTTP ?) → breadcrumb(warning)만.
      // 기기 순단·재연결 중 발생하는 환경성 오류이며 코드 결함이 아니므로
      // issue 로 올리지 않는다. 지속적 장애는 연결 상태 flapping 감지가 포착.
      if (error.isTransientNetworkError) {
        Sentry.addBreadcrumb(Breadcrumb(
          message: error.toString(),
          category: 'http',
          level: SentryLevel.warning,
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
