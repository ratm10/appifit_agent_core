/// AppFit Core 패키지
///
/// AppFit 인증 및 소켓 통신 공통 기능을 제공합니다.
library appfit_core;

// Config
export 'src/config/appfit_config.dart';
export 'src/config/sync_intervals.dart';
export 'src/config/appfit_timeouts.dart';

// Auth
export 'src/auth/token_manager.dart';
export 'src/auth/crypto_utils.dart';

// HTTP
export 'src/http/dio_provider.dart';

// Socket
export 'src/socket/notifier_service.dart';
export 'src/socket/appfit_notifier_notifier.dart';

// HTTP & Routes
export 'src/http/api_routes.dart';

// Events
export 'src/events/order_event_types.dart';
export 'src/events/socket_event_payload.dart';

// Utils
export 'src/utils/serial_async_queue.dart';

// OTA
export 'src/ota/ota_models.dart';
export 'src/ota/ota_update_manager.dart';

// Monitoring
export 'src/monitoring/monitoring_context.dart';
export 'src/monitoring/monitoring_service.dart';
export 'src/monitoring/sentry_appfit_logger.dart';
