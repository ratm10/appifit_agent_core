import 'package:dio/dio.dart';
import '../config/appfit_config.dart';
import '../config/appfit_timeouts.dart';
import '../auth/token_manager.dart';

/// 인증 상태 제공자 인터페이스
///
/// 프로젝트별로 현재 로그인된 storeId를 제공해야 합니다.
abstract class AuthStateProvider {
  String? get currentStoreId;
  String? get currentPassword;
}

/// AppFit Dio Provider
///
/// Waldlust Platform API를 위한 Dio 인스턴스를 생성합니다.
class AppFitDioProvider {
  final AppFitTokenManager tokenManager;
  final AuthStateProvider? authProvider;
  final AppFitLogger? logger;

  late final Dio dio;

  AppFitDioProvider({
    required this.tokenManager,
    this.authProvider,
    this.logger,
  }) {
    dio = Dio(
      BaseOptions(
        baseUrl: AppFitConfig.baseUrl,
        connectTimeout: AppFitTimeouts.connectTimeout,
        receiveTimeout: AppFitTimeouts.receiveTimeout,
        headers: {
          'Content-Type': 'application/json',
          // 'Waldlust-Project-ID': AppFitConfig.projectId, // 정적 헤더 제거
        },
      ),
    );

    // 인터셉터 추가
    dio.interceptors.add(_AppFitAuthInterceptor(this));
    dio.interceptors.add(_AppFitLogInterceptor(logger));
  }

  /// Dio 인스턴스 반환
  Dio get instance => dio;
}

/// 재시도 1회 제한 플래그 키 (RequestOptions.extra)
const String _kRetriedFlag = '_appfit_retried';

/// AppFit 인증 인터셉터
class _AppFitAuthInterceptor extends Interceptor {
  final AppFitDioProvider provider;

  _AppFitAuthInterceptor(this.provider);

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      // 인증이 필요 없는 엔드포인트는 스킵
      if (_isAuthEndpoint(options.path)) {
        return handler.next(options);
      }

      // shopCode 확보
      String shopCode = _getShopCodeFromOptions(options);

      // 없으면 현재 로그인된 매장 ID 사용
      if (shopCode.isEmpty) {
        shopCode = provider.authProvider?.currentStoreId ?? '';
      }

      if (shopCode.isNotEmpty) {
        var password = provider.authProvider?.currentPassword;
        if (password == null || password.isEmpty) {
          password = await provider.tokenManager.loadPassword();
        }
        final token = await provider.tokenManager.getValidToken(
          shopCode,
          password: password,
        );
        options.headers['Authorization'] = 'Bearer $token';
        await provider.logger?.log('[Dio] Authorization 헤더 추가');

        // Dynamic Project ID logic
        // (/v0/project/info 엔드포인트는 Project ID 헤더 없이 호출)
        if (!_isProjectInfoEndpoint(options.path)) {
          final storedProjectId =
              await provider.tokenManager.getStoredProjectId();
          final projectId = storedProjectId ?? AppFitConfig.projectId;

          if (projectId != null && projectId.isNotEmpty) {
            options.headers['Waldlust-Project-ID'] = projectId;
          } else {
            await provider.logger
                ?.log('[Dio] Warning: Project ID not found for request');
          }
        }
      }

      handler.next(options);
    } catch (e) {
      await provider.logger?.error('[Dio] 인증 인터셉터 오류', e);
      handler.reject(
        DioException(
          requestOptions: options,
          error: '토큰 발급 실패: $e',
          type: DioExceptionType.cancel,
        ),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // 401 에러 시 토큰 갱신 시도
    if (err.response?.statusCode == 401) {
      // 이미 한 번 재시도한 요청이면 무한 루프 방지 — 즉시 에러 전파
      if (err.requestOptions.extra[_kRetriedFlag] == true) {
        await provider.logger?.error(
          '[Dio] 401 재시도 후에도 실패: ${err.requestOptions.path}',
          null,
        );
        return handler.next(err);
      }

      await provider.logger?.log('[Dio] 401 인증 오류 - 토큰 갱신 시도');

      try {
        await provider.tokenManager.clearToken();

        String shopCode = _getShopCodeFromOptions(err.requestOptions);
        if (shopCode.isEmpty) {
          shopCode = provider.authProvider?.currentStoreId ?? '';
        }

        if (shopCode.isNotEmpty) {
          // password가 없으면 SecureStorage에서 복원 시도 후 재시도
          var password = provider.authProvider?.currentPassword;
          if (password == null || password.isEmpty) {
            password = await provider.tokenManager.loadPassword();
          }
          if (password == null || password.isEmpty) {
            await provider.logger?.error(
              '[Dio] 토큰 갱신 불가: 비밀번호가 없습니다. 재로그인이 필요합니다.',
              null,
            );
            return handler.next(err);
          }

          // TokenManager가 동시 발급을 직렬화하므로 여러 401이 동시에 와도 실제 로그인은 1회만 수행됨
          final newToken = await provider.tokenManager.getValidToken(
            shopCode,
            password: password,
          );

          // 원래 요청 재시도 (provider.dio 사용 - baseUrl 및 인터셉터 유지)
          final opts = err.requestOptions;
          opts.extra[_kRetriedFlag] = true;
          opts.headers['Authorization'] = 'Bearer $newToken';

          // Project ID 재주입 (예외 처리 포함)
          if (!_isProjectInfoEndpoint(opts.path)) {
            final storedProjectId =
                await provider.tokenManager.getStoredProjectId();
            final projectId = storedProjectId ?? AppFitConfig.projectId;
            if (projectId != null && projectId.isNotEmpty) {
              opts.headers['Waldlust-Project-ID'] = projectId;
            }
          }

          final response = await provider.dio.fetch(opts);
          return handler.resolve(response);
        }
      } catch (e) {
        await provider.logger?.error('[Dio] 토큰 갱신 실패', e);
      }
    }

    handler.next(err);
  }

  bool _isAuthEndpoint(String path) {
    return path.contains('/auth/');
  }

  bool _isProjectInfoEndpoint(String path) {
    return path.contains('/v0/project/info');
  }

  String _getShopCodeFromOptions(RequestOptions options) {
    // extra에서 가져오기
    if (options.extra.containsKey('shopCode')) {
      return options.extra['shopCode'] as String;
    }
    if (options.extra.containsKey('storeId')) {
      return options.extra['storeId'] as String;
    }

    // headers에서 가져오기
    if (options.headers.containsKey('X-Shop-Code')) {
      return options.headers['X-Shop-Code'] as String;
    }

    // queryParameters에서 가져오기
    if (options.queryParameters.containsKey('shopCode')) {
      return options.queryParameters['shopCode'] as String;
    }

    // data에서 가져오기
    if (options.data is Map) {
      final data = options.data as Map<String, dynamic>;
      if (data.containsKey('shopCode')) {
        return data['shopCode'] as String;
      }
    }

    // path에서 추출
    if (options.path.contains('/v0/shop/')) {
      final parts = options.path.split('/');
      final shopIndex = parts.indexWhere((p) => p == 'shop' || p == 'shops');
      if (shopIndex != -1 && shopIndex + 1 < parts.length) {
        return parts[shopIndex + 1];
      }
    }

    return '';
  }
}

/// AppFit 로그 인터셉터
class _AppFitLogInterceptor extends Interceptor {
  final AppFitLogger? logger;

  _AppFitLogInterceptor(this.logger);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    logger?.log('[API 요청] ${options.method} ${options.path}');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    logger?.log(
      '[API 응답] ${response.statusCode} ${response.requestOptions.path}',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    logger?.error(
      '[API 오류] ${err.response?.statusCode ?? '?'} ${err.requestOptions.path}',
      err.message,
    );
    handler.next(err);
  }
}
