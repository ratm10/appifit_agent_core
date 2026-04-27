import 'package:flutter/foundation.dart';

/// 로깅 인터페이스 (프로젝트별 구현).
///
/// 소비자 앱은 [log] 와 [error] 두 메서드만 구현하면 됩니다.
/// 세분화된 로그 레벨(`debug`/`info`/`warn`)은 [AppFitLoggerLevels] 확장을
/// 통해 자동으로 제공되며, 모두 [log] 에 위임합니다. 레벨별로 다른 경로로
/// 내보내고 싶다면 [log] 구현 내부에서 메시지 프리픽스(`[DEBUG]` 등)를
/// 파싱해 분기하세요.
abstract class AppFitLogger {
  /// 일반 로그 (INFO 수준 또는 원본 메시지).
  Future<void> log(String message);

  /// 오류 로그.
  Future<void> error(String message, dynamic error);
}

/// [AppFitLogger] 에 세분화된 레벨 메서드를 제공하는 확장.
///
/// 모든 메서드는 [AppFitLogger.log] 에 위임하며 필요한 프리픽스를 붙입니다.
/// 확장 메서드는 가상 디스패치되지 않으므로 소비자 구현체가 레벨별 동작을
/// 커스터마이즈하려면 [AppFitLogger.log] 를 오버라이드해 프리픽스로 분기하세요.
extension AppFitLoggerLevels on AppFitLogger {
  /// 디버그 로그 — `[DEBUG]` 프리픽스를 붙여 [log] 에 위임.
  Future<void> debug(String message) => log('[DEBUG] $message');

  /// 정보 로그 — 원본 메시지를 그대로 [log] 에 위임.
  Future<void> info(String message) => log(message);

  /// 경고 로그 — `[WARN]` 프리픽스를 붙여 [log] 에 위임.
  Future<void> warn(String message) => log('[WARN] $message');
}

/// 기본 로거 (콘솔 출력).
///
/// 민감한 정보가 실수로 노출되지 않도록 디버그 빌드에서만 `print` 로 출력합니다.
/// 프로덕션에서는 `SentryAppFitLogger` 같은 전용 로거를 주입하세요.
class DefaultAppFitLogger implements AppFitLogger {
  @override
  Future<void> log(String message) async {
    if (kDebugMode) print('[AppFit] $message');
  }

  @override
  Future<void> error(String message, dynamic error) async {
    if (kDebugMode) print('[AppFit ERROR] $message: $error');
  }
}
