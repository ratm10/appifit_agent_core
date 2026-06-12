import 'dart:async';
import 'dart:typed_data';

import 'package:appfit_core/appfit_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 아무것도 출력하지 않는 로거 (테스트 노이즈 억제).
class _SilentLogger implements AppFitLogger {
  const _SilentLogger();

  @override
  Future<void> log(String message) async {}

  @override
  Future<void> error(String message, dynamic error) async {}
}

/// 고정 storeId/password 를 제공하는 수동 fake.
class _FakeAuthState implements AuthStateProvider {
  _FakeAuthState({this.storeId, this.password});

  final String? storeId;
  final String? password;

  @override
  String? get currentStoreId => storeId;

  @override
  String? get currentPassword => password;
}

/// 보안 저장소/네트워크를 건드리지 않는 TokenManager fake.
///
/// `clearToken()` 마다 generation 이 올라가 "갱신된 토큰" 을 구분할 수 있다.
class _FakeTokenManager extends AppFitTokenManager {
  _FakeTokenManager({this.storedPassword, this.storedProjectId})
      : super(
          projectId: 'proj-test',
          baseUrl: 'https://unit.test',
          logger: const _SilentLogger(),
        );

  final String? storedPassword;
  final String? storedProjectId;

  int generation = 0;
  int clearTokenCalls = 0;
  final List<String> requestedShopCodes = [];
  final List<String?> requestedPasswords = [];

  @override
  Future<String> getValidToken(String shopCode, {String? password}) async {
    requestedShopCodes.add(shopCode);
    requestedPasswords.add(password);
    return 'token-gen$generation';
  }

  @override
  Future<void> clearToken() async {
    clearTokenCalls++;
    generation++;
  }

  @override
  Future<String?> loadPassword() async => storedPassword;

  @override
  Future<String?> getStoredProjectId() async => storedProjectId;
}

class _CapturedRequest {
  _CapturedRequest({
    required this.path,
    required this.headers,
    required this.extra,
  });

  final String path;
  final Map<String, dynamic> headers;
  final Map<String, dynamic> extra;
}

class _ScriptedResponse {
  const _ScriptedResponse(this.statusCode, this.body);

  final int statusCode;
  final String body;
}

/// 응답 시퀀스를 순서대로 재생하는 수동 HttpClientAdapter fake.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<_ScriptedResponse> script;
  final List<_CapturedRequest> requests = [];
  int _cursor = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(_CapturedRequest(
      path: options.path,
      headers: Map<String, dynamic>.of(options.headers),
      extra: Map<String, dynamic>.of(options.extra),
    ));
    final scripted =
        script[_cursor < script.length ? _cursor : script.length - 1];
    _cursor++;
    return ResponseBody.fromString(
      scripted.body,
      scripted.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _ok = _ScriptedResponse(200, '{"data":"ok"}');
const _unauthorized =
    _ScriptedResponse(401, '{"code":"UNAUTHORIZED","message":"token expired"}');

/// 인터셉터가 재시도 1회 제한에 쓰는 extra 플래그 키 (dio_provider.dart 내부 상수).
const String _retriedFlagKey = '_appfit_retried';

({AppFitDioProvider provider, _ScriptedAdapter adapter, _FakeTokenManager tm})
    _build({
  required List<_ScriptedResponse> script,
  _FakeAuthState? auth,
  String? storedPassword,
  String? storedProjectId = 'PRJ-001',
}) {
  final tm = _FakeTokenManager(
    storedPassword: storedPassword,
    storedProjectId: storedProjectId,
  );
  final provider = AppFitDioProvider(
    tokenManager: tm,
    authProvider: auth,
    logger: const _SilentLogger(),
  );
  final adapter = _ScriptedAdapter(script);
  provider.dio.httpClientAdapter = adapter;
  return (provider: provider, adapter: adapter, tm: tm);
}

void main() {
  group('AppFitDioProvider 요청 인터셉터', () {
    test('정상 요청에 Authorization + Waldlust-Project-ID 헤더가 붙는다', () async {
      final ctx = _build(
        script: [_ok],
        auth: _FakeAuthState(storeId: 'SHOP1', password: 'pw'),
      );

      final response = await ctx.provider.dio.get<dynamic>('/v0/order/list');

      expect(response.statusCode, 200);
      expect(ctx.adapter.requests, hasLength(1));
      final req = ctx.adapter.requests.single;
      expect(req.headers['Authorization'], 'Bearer token-gen0');
      expect(req.headers['Waldlust-Project-ID'], 'PRJ-001');
      expect(ctx.tm.requestedShopCodes, ['SHOP1']);
      expect(ctx.tm.requestedPasswords, ['pw']);
    });

    test('/auth/ 경로는 인증 처리 자체를 건너뛴다', () async {
      final ctx = _build(
        script: [_ok],
        auth: _FakeAuthState(storeId: 'SHOP1', password: 'pw'),
      );

      await ctx.provider.dio.post<dynamic>('/v0/auth/sign-in');

      final req = ctx.adapter.requests.single;
      expect(req.headers.containsKey('Authorization'), false);
      expect(req.headers.containsKey('Waldlust-Project-ID'), false);
      expect(ctx.tm.requestedShopCodes, isEmpty);
    });

    test('/v0/project/info 는 Authorization 만 붙고 Project ID 헤더는 생략된다', () async {
      final ctx = _build(
        script: [_ok],
        auth: _FakeAuthState(storeId: 'SHOP1', password: 'pw'),
      );

      await ctx.provider.dio.get<dynamic>('/v0/project/info');

      final req = ctx.adapter.requests.single;
      expect(req.headers['Authorization'], 'Bearer token-gen0');
      expect(req.headers.containsKey('Waldlust-Project-ID'), false);
    });

    test('shopCode 를 어디서도 못 찾으면 인증 헤더 없이 그대로 요청한다', () async {
      final ctx = _build(script: [_ok]); // authProvider 없음

      final response = await ctx.provider.dio.get<dynamic>('/v0/order/list');

      expect(response.statusCode, 200);
      final req = ctx.adapter.requests.single;
      expect(req.headers.containsKey('Authorization'), false);
      expect(ctx.tm.requestedShopCodes, isEmpty);
    });

    test('extra.shopCode 가 authProvider 의 storeId 보다 우선한다', () async {
      final ctx = _build(
        script: [_ok],
        auth: _FakeAuthState(storeId: 'AUTH-SHOP', password: 'pw'),
      );

      await ctx.provider.dio.get<dynamic>(
        '/v0/order/list',
        options: Options(extra: {'shopCode': 'EXTRA-SHOP'}),
      );

      expect(ctx.tm.requestedShopCodes, ['EXTRA-SHOP']);
    });

    test('/v0/shop/{code}/ 경로에서 shopCode 를 추출한다', () async {
      final ctx = _build(script: [_ok]); // authProvider 없음

      await ctx.provider.dio.get<dynamic>('/v0/shop/SHOP9/orders');

      expect(ctx.tm.requestedShopCodes, ['SHOP9']);
    });
  });

  group('AppFitDioProvider 401 재시도', () {
    test('401 → 토큰 갱신 → 원요청 1회 재시도 후 성공한다', () async {
      final ctx = _build(
        script: [_unauthorized, _ok],
        auth: _FakeAuthState(storeId: 'SHOP1', password: 'pw'),
      );

      final response = await ctx.provider.dio.get<dynamic>('/v0/order/list');

      expect(response.statusCode, 200);
      expect(ctx.adapter.requests, hasLength(2));
      expect(ctx.tm.clearTokenCalls, 1);

      // 1차 요청: 갱신 전 토큰
      expect(ctx.adapter.requests[0].headers['Authorization'],
          'Bearer token-gen0');
      expect(ctx.adapter.requests[0].extra.containsKey(_retriedFlagKey), false);

      // 재시도 요청: clearToken 이후 발급된 새 토큰 + 재시도 플래그
      expect(ctx.adapter.requests[1].headers['Authorization'],
          'Bearer token-gen1');
      expect(ctx.adapter.requests[1].extra[_retriedFlagKey], true);
      expect(ctx.adapter.requests[1].headers['Waldlust-Project-ID'], 'PRJ-001');
    });

    test('현재 동작 고정: 재시도 요청도 onRequest 를 다시 통과해 getValidToken 이 총 3회 호출된다',
        () async {
      // onError 가 세팅한 Authorization 을 onRequest 가 같은 토큰으로 덮어쓴다.
      // (실제 TokenManager 는 캐시 hit 라 부작용은 없지만 이중 처리임)
      final ctx = _build(
        script: [_unauthorized, _ok],
        auth: _FakeAuthState(storeId: 'SHOP1', password: 'pw'),
      );

      await ctx.provider.dio.get<dynamic>('/v0/order/list');

      // 1차 onRequest + onError 갱신 + 재시도 onRequest
      expect(ctx.tm.requestedShopCodes, ['SHOP1', 'SHOP1', 'SHOP1']);
    });

    test('재시도 후에도 401 이면 더 재시도하지 않고 에러를 전파한다 (무한 루프 방지)', () async {
      final ctx = _build(
        script: [_unauthorized, _unauthorized],
        auth: _FakeAuthState(storeId: 'SHOP1', password: 'pw'),
      );

      await expectLater(
        ctx.provider.dio.get<dynamic>('/v0/order/list'),
        throwsA(isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          401,
        )),
      );
      expect(ctx.adapter.requests, hasLength(2));
      // 두 번째 401 은 재시도 플래그 때문에 갱신 없이 즉시 전파 → clearToken 1회뿐
      expect(ctx.tm.clearTokenCalls, 1);
    });

    test('현재 동작 고정: shopCode 를 못 찾는 401 도 clearToken 은 수행된다', () async {
      final ctx = _build(script: [_unauthorized]); // authProvider 없음

      await expectLater(
        ctx.provider.dio.get<dynamic>('/v0/order/list'),
        throwsA(isA<DioException>().having(
          (e) => e.response?.statusCode,
          'statusCode',
          401,
        )),
      );
      expect(ctx.adapter.requests, hasLength(1), reason: '재시도 없음');
      expect(ctx.tm.clearTokenCalls, 1, reason: '갱신 불가 상황에서도 저장 토큰을 무조건 비운다');
    });

    test('비밀번호가 어디에도 없으면 401 갱신을 포기하고 에러를 전파한다', () async {
      final ctx = _build(
        script: [_unauthorized],
        auth: _FakeAuthState(storeId: 'SHOP1'), // password 없음
        storedPassword: null,
      );

      await expectLater(
        ctx.provider.dio.get<dynamic>('/v0/order/list'),
        throwsA(isA<DioException>()),
      );
      expect(ctx.adapter.requests, hasLength(1));
      expect(ctx.tm.clearTokenCalls, 1);
      // onRequest 1회 외에 onError 에서의 재발급 호출이 없다
      expect(ctx.tm.requestedShopCodes, ['SHOP1']);
    });

    test('authProvider 의 password 가 없으면 loadPassword 로 복원해 갱신한다', () async {
      final ctx = _build(
        script: [_unauthorized, _ok],
        auth: _FakeAuthState(storeId: 'SHOP1'), // 세션 password 없음
        storedPassword: 'stored-pw',
      );

      final response = await ctx.provider.dio.get<dynamic>('/v0/order/list');

      expect(response.statusCode, 200);
      // onRequest/onError/재시도 onRequest 모두 SecureStorage 비밀번호 사용
      expect(
          ctx.tm.requestedPasswords, ['stored-pw', 'stored-pw', 'stored-pw']);
    });
  });

  group('AppFitTokenManager 동시 발급 직렬화', () {
    test('진행 중 발급이 있으면 후속 호출이 합류해 발급은 1회만 수행된다', () async {
      final tm = _GatedTokenManager();

      final first = tm.getValidToken('SHOP_A', password: 'pw');
      // 첫 호출이 저장소 확인을 지나 발급 단계에 진입할 때까지 양보
      await _pumpUntil(() => tm.gates.isNotEmpty);

      final second = tm.getValidToken('SHOP_A', password: 'pw');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tm.issueCalls, 1, reason: '두 번째 호출은 in-flight future 에 합류');

      tm.gates.single.complete(_tokenInfo('T-1'));
      expect(await first, 'T-1');
      expect(await second, 'T-1');
      expect(tm.issueCalls, 1);
    });

    test('발급 완료 후 같은 shopCode 호출은 캐시를 사용한다 (추가 발급 없음)', () async {
      final tm = _GatedTokenManager();

      final first = tm.getValidToken('SHOP_A', password: 'pw');
      await _pumpUntil(() => tm.gates.isNotEmpty);
      tm.gates.single.complete(_tokenInfo('T-1'));
      expect(await first, 'T-1');

      expect(await tm.getValidToken('SHOP_A', password: 'pw'), 'T-1');
      expect(tm.issueCalls, 1);
    });

    test('발급 완료 후 다른 shopCode 호출은 캐시를 폐기하고 새로 발급한다', () async {
      final tm = _GatedTokenManager();

      final first = tm.getValidToken('SHOP_A', password: 'pw');
      await _pumpUntil(() => tm.gates.isNotEmpty);
      tm.gates.single.complete(_tokenInfo('T-A'));
      expect(await first, 'T-A');

      final second = tm.getValidToken('SHOP_B', password: 'pw');
      await _pumpUntil(() => tm.gates.length == 2);
      tm.gates[1].complete(_tokenInfo('T-B'));
      expect(await second, 'T-B');
      expect(tm.issuedShopCodes, ['SHOP_A', 'SHOP_B']);
    });

    test('현재 동작 고정(버그 의심): 다른 shopCode 호출도 진행 중 발급에 합류해 남의 토큰을 받는다', () async {
      // in-flight 합류(_refreshingFuture) 시 shopCode 일치 검증이 없어
      // SHOP_B 요청이 SHOP_A 용으로 발급 중인 토큰을 그대로 돌려받는다.
      final tm = _GatedTokenManager();

      final first = tm.getValidToken('SHOP_A', password: 'pw');
      await _pumpUntil(() => tm.gates.isNotEmpty);

      final second = tm.getValidToken('SHOP_B', password: 'pw');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tm.issueCalls, 1, reason: 'SHOP_B 용 발급이 일어나지 않음');

      tm.gates.single.complete(_tokenInfo('T-A'));
      expect(await first, 'T-A');
      expect(await second, 'T-A', reason: 'SHOP_B 가 SHOP_A 토큰을 수신');
      expect(tm.issuedShopCodes, ['SHOP_A']);
    });

    test('issueToken 은 password 없이 호출하면 Exception 을 던진다', () async {
      final tm = AppFitTokenManager(
        projectId: 'P',
        baseUrl: 'https://unit.test',
        logger: const _SilentLogger(),
      );
      await expectLater(
        tm.issueToken('SHOP_A'),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString',
          contains('비밀번호가 필요합니다'),
        )),
      );
    });
  });

  group('TokenInfo', () {
    test('isExpired / isExpiringSoon 은 만료 시각 기준으로 판정한다', () {
      final fresh = _tokenInfo('T', ttl: const Duration(hours: 2));
      expect(fresh.isExpired, false);
      expect(fresh.isExpiringSoon, false);

      final soon = _tokenInfo('T', ttl: const Duration(minutes: 30));
      expect(soon.isExpired, false);
      expect(soon.isExpiringSoon, true);

      final expired = _tokenInfo('T', ttl: const Duration(minutes: -1));
      expect(expired.isExpired, true);
      expect(expired.isExpiringSoon, true);
    });

    test('toString 에 토큰 값이 노출되지 않는다', () {
      final info = _tokenInfo('SECRET-TOKEN');
      expect(info.toString(), isNot(contains('SECRET-TOKEN')));
    });
  });
}

TokenInfo _tokenInfo(String token, {Duration ttl = const Duration(days: 1)}) {
  return TokenInfo(token: token, expiresAt: DateTime.now().add(ttl));
}

/// 조건이 참이 될 때까지 이벤트 루프를 양보한다 (최대 ~1초).
Future<void> _pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), true, reason: '대기 조건이 시간 내에 충족되지 않음');
}

/// issueToken 완료 시점을 테스트가 제어하는 TokenManager.
///
/// getValidToken/clearToken 등 직렬화 로직은 실제 구현을 그대로 사용한다.
/// (보안 저장소 접근은 실패해도 내부 try/catch 로 무시되어 null/no-op 처리됨)
class _GatedTokenManager extends AppFitTokenManager {
  _GatedTokenManager()
      : super(
          projectId: 'P',
          baseUrl: 'https://unit.test',
          logger: const _SilentLogger(),
        );

  int issueCalls = 0;
  final List<String> issuedShopCodes = [];
  final List<Completer<TokenInfo>> gates = [];

  @override
  Future<TokenInfo> issueToken(String shopCode, {String? password}) {
    issueCalls++;
    issuedShopCodes.add(shopCode);
    final gate = Completer<TokenInfo>();
    gates.add(gate);
    return gate.future;
  }
}
