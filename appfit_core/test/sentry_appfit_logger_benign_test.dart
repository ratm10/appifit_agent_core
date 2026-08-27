import 'package:appfit_core/appfit_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// `SentryAppFitLogger.isBenign` 계약 고정.
///
/// benign = Sentry issue 를 만들지 않고 breadcrumb 으로만 남기는 오류.
/// 판정이 **넓어지는 쪽**이 위험하다 — 범용 검증 코드를 전역으로 열어두면
/// 우리가 잘못된 요청을 보내는 진짜 결함까지 조용히 묻힌다. 그래서
/// `INVALID_REQUEST` 는 엔드포인트 단위로만 허용한다.
ApiHttpException _api({
  required String path,
  String method = 'POST',
  int? status = 400,
  String? code,
}) {
  final options = RequestOptions(path: path, method: method);
  return ApiHttpException.fromDio(DioException(
    requestOptions: options,
    response: Response<Object?>(
      requestOptions: options,
      statusCode: status,
      data: code == null ? null : <String, dynamic>{'code': code},
    ),
    type: DioExceptionType.badResponse,
  ));
}

void main() {
  group('전역 benign 코드', () {
    test('INVALID_ORDER_STATUS 는 경로와 무관하게 benign', () {
      expect(
        SentryAppFitLogger.isBenign(_api(
          path: '/v0/order/849083306090384177',
          method: 'PUT',
          code: 'INVALID_ORDER_STATUS',
        )),
        isTrue,
      );
    });
  });

  group('경로 단위 benign 코드', () {
    test('쿠폰 사용 경로의 INVALID_REQUEST 는 benign (운영자 입력 오류)', () {
      expect(
        SentryAppFitLogger.isBenign(_api(
          path: '/v0/coupon/01092337380/use-without-item',
          code: 'INVALID_REQUEST',
        )),
        isTrue,
      );
    });

    test('같은 INVALID_REQUEST 라도 다른 경로면 issue 로 남긴다', () {
      // 이게 무너지면 "우리가 잘못된 본문을 보냈다"는 진짜 결함이 묻힌다.
      expect(
        SentryAppFitLogger.isBenign(_api(
          path: '/v0/order/849083306090384177/status',
          method: 'PUT',
          code: 'INVALID_REQUEST',
        )),
        isFalse,
      );
    });

    test('쿠폰 경로여도 등록되지 않은 코드면 issue 로 남긴다', () {
      expect(
        SentryAppFitLogger.isBenign(_api(
          path: '/v0/coupon/01092337380/use-without-item',
          code: 'INTERNAL_ERROR',
        )),
        isFalse,
      );
    });

    test('쿠폰 사용취소·검증은 별도 경로라 열려 있지 않다', () {
      for (final path in [
        '/v0/coupon/5001868426241491/use-cancel',
        '/v0/coupon/5001868426241491/validate',
      ]) {
        expect(
          SentryAppFitLogger.isBenign(
              _api(path: path, code: 'INVALID_REQUEST')),
          isFalse,
          reason: path,
        );
      }
    });
  });

  group('code 없음', () {
    test('서버 code 가 없으면 benign 이 아니다', () {
      expect(
        SentryAppFitLogger.isBenign(_api(
          path: '/v0/coupon/01092337380/use-without-item',
        )),
        isFalse,
      );
    });
  });
}
