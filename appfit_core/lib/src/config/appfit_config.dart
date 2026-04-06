/// Waldlust Platform AppFit 설정
///
/// 환경별 API URL 및 설정을 관리합니다.
class AppFitConfig {
  /// API 환경 (기본값: live)
  static AppFitEnvironment _environment = AppFitEnvironment.live;

  /// Project ID
  static String? _projectId;

  /// 요청 출처 (DID, KIOSK, ORDER_AGENT 등)
  static String _requestSource = '';

  /// 환경 설정
  static void configure({
    required AppFitEnvironment environment,
    String? projectId,
    required String requestSource,
  }) {
    _environment = environment;
    _projectId = projectId;
    _requestSource = requestSource;
  }

  /// 현재 환경
  static AppFitEnvironment get environment => _environment;

  /// 현재 환경의 Base URL
  static String get baseUrl => _environment.baseUrl;

  /// 현재 환경의 WebSocket URL
  static String get websocketUrl => _environment.websocketUrl;

  /// Project ID (Optional)
  static String? get projectId => _projectId;

  /// 요청 출처
  static String get requestSource => _requestSource;

  /// 설정이 완료되었는지 확인 (Project ID는 선택 사항이므로 변경)
  static bool isConfigured() {
    return _requestSource.isNotEmpty;
  }

  /// 환경 설정 정보 출력 (디버깅용, 민감한 정보는 마스킹)
  static String getConfigSummary() {
    try {
      return '''
AppFit API 설정:
- 환경: ${_environment.name}
- Base URL: $baseUrl
- WebSocket URL: $websocketUrl
- Project ID: ${_mask(_projectId)}
- Request Source: $_requestSource
''';
    } catch (e) {
      return 'AppFit API 설정 오류: $e';
    }
  }

  /// 민감한 정보 마스킹
  static String _mask(String? value) {
    if (value == null || value.isEmpty) return 'N/A';
    if (value.length <= 8) return '****';
    return '${value.substring(0, 4)}****${value.substring(value.length - 4)}';
  }
}

/// AppFit API 환경
enum AppFitEnvironment {
  /// 개발 환경
  dev(
    baseUrl: 'https://core-devapi.waldplatform.com',
    websocketUrl: 'wss://notifier-devapi.waldplatform.com',
  ),

  /// 스테이징 환경
  staging(
    baseUrl: 'https://core-stgapi.waldplatform.com',
    websocketUrl: 'wss://notifier-stgapi.waldplatform.com',
  ),

  /// 운영 환경
  live(
    baseUrl: 'https://core-api.waldplatform.com',
    websocketUrl: 'wss://notifier-api.waldplatform.com',
  ),

  /// Japan 운영 환경
  japanLive(
    baseUrl: 'https://core-jpapi.waldplatform.com',
    websocketUrl: 'wss://notifier-jpapi.waldplatform.com',
  );

  final String baseUrl;
  final String websocketUrl;

  const AppFitEnvironment({
    required this.baseUrl,
    required this.websocketUrl,
  });
}
