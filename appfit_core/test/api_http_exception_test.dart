import 'package:appfit_core/appfit_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// DioException 수동 팩토리 — 응답 본문/헤더/상태를 조립한다.
DioException _dioError({
  String path = '/v0/order/849083306090384177',
  String method = 'PUT',
  int? status = 400,
  Object? data,
  Map<String, List<String>>? headers,
}) {
  final options = RequestOptions(path: path, method: method);
  final response = status == null
      ? null
      : Response<Object?>(
          requestOptions: options,
          statusCode: status,
          data: data,
          headers: Headers.fromMap(headers ?? <String, List<String>>{}),
        );
  return DioException(
    requestOptions: options,
    response: response,
    type: status == null
        ? DioExceptionType.connectionError
        : DioExceptionType.badResponse,
  );
}

void main() {
  group('ApiHttpException.templatePath', () {
    test('3자리 이상 숫자 세그먼트는 {id} 로 치환된다', () {
      expect(
        ApiHttpException.templatePath('/v0/order/849083306090384177'),
        '/v0/order/{id}',
      );
      expect(ApiHttpException.templatePath('/v0/order/123'), '/v0/order/{id}');
    });

    test('2자리 이하 숫자 세그먼트는 치환되지 않는다', () {
      expect(ApiHttpException.templatePath('/v0/order/12'), '/v0/order/12');
      expect(ApiHttpException.templatePath('/v0/order/1'), '/v0/order/1');
    });

    test('다중 식별자 세그먼트는 각각 치환된다', () {
      expect(
        ApiHttpException.templatePath('/v0/shop/12345/order/678901'),
        '/v0/shop/{id}/order/{id}',
      );
    });

    test('현재 동작 고정: 영숫자 혼합/UUID 등 비숫자 식별자는 치환되지 않는다', () {
      // doc 주석은 "숫자/긴 식별자 세그먼트" 치환이라 표현하지만,
      // 실제 정규식은 ^\d{3,}$ 로 순수 숫자만 치환한다.
      expect(
        ApiHttpException.templatePath('/v0/order/abc123def'),
        '/v0/order/abc123def',
      );
      expect(
        ApiHttpException.templatePath(
          '/v0/shop/550e8400-e29b-41d4-a716-446655440000',
        ),
        '/v0/shop/550e8400-e29b-41d4-a716-446655440000',
      );
    });
  });

  group('ApiHttpException.fromDio', () {
    test('서버 본문(code/message)/상태/requestId/경로를 추출한다', () {
      final exception = ApiHttpException.fromDio(_dioError(
        data: <String, dynamic>{
          'code': 'INVALID_ORDER_STATUS',
          'message': '이미 픽업 요청된 주문입니다.',
        },
        headers: {
          'x-request-id': ['req-123'],
        },
      ));

      expect(exception.status, 400);
      expect(exception.method, 'PUT');
      expect(exception.path, '/v0/order/{id}');
      expect(exception.rawPath, '/v0/order/849083306090384177');
      expect(exception.code, 'INVALID_ORDER_STATUS');
      expect(exception.serverMessage, '이미 픽업 요청된 주문입니다.');
      expect(exception.requestId, 'req-123');
    });

    test('본문이 Map 이 아니면 code/serverMessage 는 null', () {
      final exception = ApiHttpException.fromDio(
        _dioError(data: '<html>Bad Gateway</html>', status: 502),
      );
      expect(exception.status, 502);
      expect(exception.code, isNull);
      expect(exception.serverMessage, isNull);
    });

    test('code 가 숫자여도 toString 으로 문자열화한다', () {
      final exception = ApiHttpException.fromDio(
        _dioError(data: <String, dynamic>{'code': 4001, 'message': 'oops'}),
      );
      expect(exception.code, '4001');
    });

    test('응답 자체가 없으면(연결 오류) status/requestId 가 null', () {
      final exception = ApiHttpException.fromDio(
        _dioError(status: null, method: 'GET', path: '/v0/shop/info'),
      );
      expect(exception.status, isNull);
      expect(exception.code, isNull);
      expect(exception.serverMessage, isNull);
      expect(exception.requestId, isNull);
    });

    test('원본 DioException 이 cause 로 보존된다', () {
      final err = _dioError();
      final exception = ApiHttpException.fromDio(err);
      expect(identical(exception.cause, err), true);
    });
  });

  group('ApiHttpException.toString', () {
    test('상태/메서드/경로/code/메시지를 " · " 로 연결한다', () {
      final exception = ApiHttpException.fromDio(_dioError(
        data: <String, dynamic>{
          'code': 'INVALID_ORDER_STATUS',
          'message': '이미 픽업 요청된 주문입니다.',
        },
      ));
      expect(
        exception.toString(),
        'HTTP 400 PUT /v0/order/{id} · INVALID_ORDER_STATUS'
        ' · 이미 픽업 요청된 주문입니다.',
      );
    });

    test('code/메시지 없으면 헤더 부분만 출력한다', () {
      final exception = ApiHttpException.fromDio(_dioError(data: 'plain'));
      expect(exception.toString(), 'HTTP 400 PUT /v0/order/{id}');
    });

    test('빈 문자열 메시지는 제외되고 code 만 붙는다', () {
      final exception = ApiHttpException.fromDio(_dioError(
        data: <String, dynamic>{'code': 'X', 'message': ''},
      ));
      expect(exception.toString(), 'HTTP 400 PUT /v0/order/{id} · X');
    });

    test('status 가 null 이면 "?" 로 표기한다', () {
      final exception = ApiHttpException.fromDio(
        _dioError(status: null, method: 'GET', path: '/v0/shop/info'),
      );
      expect(exception.toString(), 'HTTP ? GET /v0/shop/info');
    });
  });

  group('ApiHttpException.fingerprint', () {
    test('http/메서드/템플릿경로/상태/서버코드 순으로 구성된다', () {
      final exception = ApiHttpException.fromDio(_dioError(
        data: <String, dynamic>{'code': 'INVALID_ORDER_STATUS'},
      ));
      expect(exception.fingerprint, [
        'http',
        'PUT',
        '/v0/order/{id}',
        '400',
        'INVALID_ORDER_STATUS',
      ]);
    });

    test('code 없으면 4개 요소, status null 은 "?" 가 들어간다', () {
      final noCode = ApiHttpException.fromDio(_dioError(data: 'plain'));
      expect(noCode.fingerprint, ['http', 'PUT', '/v0/order/{id}', '400']);

      final noResponse = ApiHttpException.fromDio(
        _dioError(status: null, method: 'GET', path: '/v0/shop/info'),
      );
      expect(noResponse.fingerprint, ['http', 'GET', '/v0/shop/info', '?']);
    });
  });

  group('ApiHttpException.toExtras', () {
    test('항상 포함되는 키와 조건부 키를 구분한다', () {
      final full = ApiHttpException.fromDio(_dioError(
        data: <String, dynamic>{'code': 'C', 'message': 'M'},
        headers: {
          'x-request-id': ['req-9'],
        },
      ));
      expect(full.toExtras(), {
        'http.method': 'PUT',
        'http.path': '/v0/order/{id}',
        'http.status': 400,
        'server.code': 'C',
        'server.message': 'M',
        'request_id': 'req-9',
      });

      final minimal = ApiHttpException.fromDio(
        _dioError(status: null, method: 'GET', path: '/v0/shop/info'),
      );
      expect(minimal.toExtras(), {
        'http.method': 'GET',
        'http.path': '/v0/shop/info',
        'http.status': null,
      });
    });
  });
}
