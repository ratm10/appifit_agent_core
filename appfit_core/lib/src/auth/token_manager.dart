import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/appfit_timeouts.dart';
import '../logging/appfit_logger.dart';
import 'crypto_utils.dart';

/// JWT 토큰 정보
class TokenInfo {
  final String token;
  final DateTime expiresAt;

  TokenInfo({required this.token, required this.expiresAt});

  factory TokenInfo.fromJson(Map<String, dynamic> json) {
    return TokenInfo(
      token: json['token'] as String,
      expiresAt: DateTime.parse(json['expiresAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {'token': token, 'expiresAt': expiresAt.toIso8601String()};
  }

  /// 토큰이 만료되었는지 확인 (실제 만료 시각 기준)
  bool get isExpired {
    return DateTime.now().isAfter(expiresAt);
  }

  /// 토큰이 곧 만료될지 확인 (1시간 이내)
  bool get isExpiringSoon {
    return DateTime.now().isAfter(expiresAt.subtract(const Duration(hours: 1)));
  }
}

/// Waldlust Platform AppFit 토큰 관리자
///
/// JWT 토큰 발급, 저장, 갱신을 담당합니다.
class AppFitTokenManager {
  static const String _tokenKey = 'appfit_jwt_token';
  static const String _tokenExpiresKey = 'appfit_jwt_expires';
  static const String _dynamicApiKeyKey = 'appfit_dynamic_api_key';
  static const String _appFitProjectId = 'appfit_project_id';
  static const String _appFitProjectApiKey = 'appfit_project_api_key';
  static const String _passwordKey = 'appfit_shop_password';

  final String projectId;
  final String baseUrl;
  final AppFitLogger _logger;
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  TokenInfo? _cachedToken;

  /// 동시 갱신 직렬화용 future — 진행 중인 발급이 있으면 후속 요청이 공유
  Future<String>? _refreshingFuture;

  AppFitTokenManager({
    required this.projectId,
    required this.baseUrl,
    AppFitLogger? logger,
  }) : _logger = logger ?? DefaultAppFitLogger();

  /// 유효한 토큰 가져오기 (자동 갱신 포함)
  /// Method 2 (로그인 방식) 사용 시 password 인자가 필요합니다.
  ///
  /// 여러 요청이 동시에 만료된 토큰을 가지고 호출해도 내부적으로 발급은 1회만 수행됩니다.
  Future<String> getValidToken(String shopCode, {String? password}) async {
    // 1. 캐시된 토큰 확인
    if (_cachedToken != null && !_cachedToken!.isExpired) {
      await _logger.log('[Token] 캐시된 토큰 사용');
      return _cachedToken!.token;
    }

    // 2. 저장된 토큰 확인
    final savedToken = await _loadTokenFromStorage();
    if (savedToken != null && !savedToken.isExpired) {
      await _logger.log('[Token] 저장된 토큰 사용');
      _cachedToken = savedToken;
      return savedToken.token;
    }

    // 3. 진행 중인 갱신이 있으면 결과 공유 (동시 401 중복 발급 방지)
    final inFlight = _refreshingFuture;
    if (inFlight != null) {
      await _logger.log('[Token] 기존 발급 요청에 합류');
      return inFlight;
    }

    // 4. 새 토큰 발급 — 완료될 때까지 후속 호출이 공유할 수 있도록 저장
    final future = _issueAndCache(shopCode, password: password);
    _refreshingFuture = future;
    try {
      return await future;
    } finally {
      _refreshingFuture = null;
    }
  }

  Future<String> _issueAndCache(String shopCode, {String? password}) async {
    await _logger.log('[Token] 새 토큰 발급 (Method 2: 로그인)');
    final newToken = await issueToken(shopCode, password: password);
    await _saveTokenToStorage(newToken);
    _cachedToken = newToken;
    return newToken.token;
  }

  /// 토큰 발급 (매장 관리자 로그인 방식 - Method 2)
  Future<TokenInfo> issueToken(String shopCode, {String? password}) async {
    if (password == null || password.isEmpty) {
      throw Exception('로그인 방식을 사용하려면 비밀번호가 필요합니다.');
    }

    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: AppFitTimeouts.connectTimeout,
          receiveTimeout: AppFitTimeouts.receiveTimeout,
        ),
      );

      // 요청 본문 생성
      final requestBody = {'id': shopCode, 'password': password};

      await _logger.log('[Token] 로그인 요청 시작');
      await _logger.log('- Base URL: $baseUrl');
      await _logger.log('- Endpoint: /v0/auth/sign-in');

      // API 요청 (Method 2: /v0/auth/sign-in)
      final response = await dio.post(
        '/v0/auth/sign-in',
        data: requestBody,
        options: Options(headers: {'Content-Type': 'application/json'}),
      );

      await _logger.log('[Token] 로그인 응답 성공!: ${response.statusCode}');

      // 응답 파싱
      if (response.statusCode == 200) {
        final data = response.data['data'] as Map<String, dynamic>;
        final tokenInfo = TokenInfo.fromJson(data);

        final daysUntilExpiry =
            tokenInfo.expiresAt.difference(DateTime.now()).inDays;
        await _logger.log(
          '[Token] 로그인 성공 및 토큰 발급 완료, 만료: ${tokenInfo.expiresAt} (${daysUntilExpiry}일 후)',
        );
        return tokenInfo;
      } else {
        throw Exception('로그인 실패: ${response.statusCode}');
      }
    } on DioException catch (e) {
      await _logger.error('[Token] 로그인 요청 오류: ${e.message}', null);
      if (e.response != null) {
        await _logger.error('- Error Response: ${e.response?.data}', null);

        // 서버 에러 응답의 message 필드 추출
        if (e.response?.data is Map) {
          final data = e.response?.data as Map;
          final serverMessage = data['message'];
          if (serverMessage != null && serverMessage.toString().isNotEmpty) {
            throw Exception('로그인 API 오류: $serverMessage');
          }
        }
      }
      throw Exception('로그인 API 오류: ${e.message}');
    } catch (e) {
      await _logger.error('[Token] 로그인 실패: $e', null);
      rethrow;
    }
  }

  /// 토큰을 보안 저장소에 저장
  Future<void> _saveTokenToStorage(TokenInfo tokenInfo) async {
    try {
      await _storage.write(key: _tokenKey, value: tokenInfo.token);
      await _storage.write(
        key: _tokenExpiresKey,
        value: tokenInfo.expiresAt.toIso8601String(),
      );
      await _logger.log('[Token] 토큰 보안 저장 완료');
    } catch (e) {
      await _logger.error('[Token] 토큰 저장 실패: $e', null);
    }
  }

  /// 보안 저장소에서 토큰 로드
  Future<TokenInfo?> _loadTokenFromStorage() async {
    try {
      final token = await _storage.read(key: _tokenKey);
      final expiresStr = await _storage.read(key: _tokenExpiresKey);

      if (token != null && expiresStr != null) {
        return TokenInfo(token: token, expiresAt: DateTime.parse(expiresStr));
      }
      return null;
    } catch (e) {
      await _logger.error('[Token] 토큰 로드 실패: $e', null);
      return null;
    }
  }

  /// Project API Key 유효성 검증
  Future<bool> validateApiKey() async {
    try {
      // 0. 저장소에서 최신 정보 가져오기 시도
      final storedId = await _storage.read(key: _appFitProjectId);
      final storedKey = await _storage.read(key: _appFitProjectApiKey);

      if (storedId == null ||
          storedId.isEmpty ||
          storedKey == null ||
          storedKey.isEmpty) {
        await _logger.error(
          '[Token] Project ID 또는 API Key가 저장소에 없습니다. 로그인을 먼저 수행하세요.',
          null,
        );
        return false;
      }

      final dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: AppFitTimeouts.connectTimeout,
          receiveTimeout: AppFitTimeouts.receiveTimeout,
        ),
      );

      // 1. 요청 본문 생성
      // 가이드: UTC, ISO-8601 (YYYY-MM-DDTHH:MM:SS.SSS) - 밀리초 3자리 고정
      final now = DateTime.now().toUtc();
      String isoString =
          now.toIso8601String(); // e.g., 2026-01-12T04:20:10.164833Z
      if (isoString.endsWith('Z')) {
        isoString = isoString.substring(0, isoString.length - 1);
      }

      String formattedDatetime;
      if (isoString.contains('.')) {
        final parts = isoString.split('.');
        final seconds = parts[0];
        String fraction = parts[1];
        if (fraction.length > 3) {
          fraction = fraction.substring(0, 3); // 6자리 -> 3자리 절삭
        } else {
          fraction = fraction.padRight(3, '0'); // 1~2자리 -> 3자리 패딩
        }
        formattedDatetime = '$seconds.$fraction'; // Z 미포함
      } else {
        formattedDatetime = '$isoString.000'; // 정각일 경우 .000 추가
      }

      final requestBody = {
        'projectId': storedId,
        'version': 1,
        'requestSource': 'AGENT',
        'datetime': formattedDatetime,
      };

      // 2. Compact JSON 생성
      final payload = CryptoUtils.createCompactJson(requestBody);

      // 3. HMAC-SHA512 서명 생성
      final signature = CryptoUtils.generateHmacSha512Signature(
        storedKey,
        payload,
      );

      await _logger.log('[Token] API Key 검증 요청 시작');

      // 4. API 요청
      final response = await dio.post(
        '/v0/auth/api-key/validate',
        data: requestBody,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Waldlust-Signature': signature,
          },
        ),
      );

      await _logger.log('[Token] API Key 검증 응답 성공: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = response.data['data'] as Map<String, dynamic>;
        final isActive = data['isActive'] as bool;
        await _logger.log('[Token] API Key 검증 성공: isActive=$isActive');
        return isActive;
      } else {
        await _logger.error(
          '[Token] API Key 검증 실패: ${response.statusCode}',
          null,
        );
        return false;
      }
    } on DioException catch (e) {
      await _logger.error('[Token] API Key 검증 오류: ${e.message}', null);
      if (e.response != null) {
        await _logger.error('- Error Response: ${e.response?.data}', null);
      }
      return false;
    } catch (e) {
      await _logger.error('[Token] API Key 검증 실패: $e', null);
      return false;
    }
  }

  /// 비밀번호를 보안 저장소에 저장 (장시간 세션 토큰 갱신용).
  ///
  /// ⚠️ 보안 경고: `FlutterSecureStorage`가 플랫폼 보안 저장소(iOS Keychain,
  /// Android Keystore)를 사용하지만 저장되는 값 자체는 평문입니다. 플랫폼 보안이
  /// 손상(루팅·탈옥·백업 추출 등)되면 노출될 수 있으므로, 장기적으로는 refresh
  /// token 등의 passwordless 패턴으로 전환하는 것이 바람직합니다.
  Future<void> savePassword(String password) async {
    try {
      await _storage.write(key: _passwordKey, value: password);
      await _logger.log('[Token] 비밀번호 보안 저장 완료');
    } catch (e) {
      await _logger.error('[Token] 비밀번호 저장 실패: $e', null);
    }
  }

  /// 저장된 비밀번호 조회.
  ///
  /// ⚠️ [savePassword]와 동일한 보안 경고가 적용됩니다. 결과를 로그로 남기지
  /// 말고, 사용 직후 지역 변수에서 소거하거나 가능한 한 메모리 잔존을 최소화하세요.
  Future<String?> loadPassword() async {
    try {
      return await _storage.read(key: _passwordKey);
    } catch (e) {
      await _logger.error('[Token] 비밀번호 로드 실패: $e', null);
      return null;
    }
  }

  /// 저장된 비밀번호 삭제 (로그아웃 시)
  Future<void> clearPassword() async {
    try {
      await _storage.delete(key: _passwordKey);
      await _logger.log('[Token] 비밀번호 보안 삭제 완료');
    } catch (e) {
      await _logger.error('[Token] 비밀번호 삭제 실패: $e', null);
    }
  }

  /// Project ID와 API Key 저장
  Future<void> saveProjectCredentials(String projectId, String apiKey) async {
    await _storage.write(key: _appFitProjectId, value: projectId);
    await _storage.write(key: _appFitProjectApiKey, value: apiKey);
  }

  /// 저장된 Project ID 조회
  Future<String?> getStoredProjectId() async {
    return await _storage.read(key: _appFitProjectId);
  }

  /// 토큰 제거 (로그아웃 시)
  Future<void> clearToken() async {
    try {
      await _storage.delete(key: _tokenKey);
      await _storage.delete(key: _tokenExpiresKey);
      await _storage.delete(key: _dynamicApiKeyKey);
      _cachedToken = null;
      await _logger.log('[Token] 토큰 보안 제거 완료');
    } catch (e) {
      await _logger.error('[Token] 토큰 제거 실패: $e', null);
    }
  }
}
