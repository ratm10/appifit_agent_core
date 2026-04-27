import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../auth/crypto_utils.dart';
import '../config/appfit_config.dart';
import '../logging/appfit_logger.dart';

/// WebSocket 연결 상태
enum ConnectionStatus {
  connected,          // 정상 연결됨 (초기 연결 또는 재연결 구분 없이 범용)
  initialConnected,   // 첫 연결 성공 (앱 시작/로그인 후 최초)
  reconnected,        // 재연결 성공 (끊김 후 복구)
  reconnecting,       // 재연결 시도 중 (backoff 대기 포함)
  disconnected,       // 연결 끊김 (최대 재연결 횟수 초과 또는 의도적 종료)
}

/// ConnectionStatus 확장 - 연결됨 상태 편의 getter
extension ConnectionStatusExtension on ConnectionStatus {
  /// connected, initialConnected, reconnected 중 하나이면 true
  bool get isConnected =>
      this == ConnectionStatus.connected ||
      this == ConnectionStatus.initialConnected ||
      this == ConnectionStatus.reconnected;
}

/// AppFit 전용 WebSocket 알림 서비스
///
/// AppFit 매장의 실시간 주문/상태 알림을 처리합니다.
/// 내부적으로 backoff 재연결 + 네트워크 복원 감지를 완전히 처리합니다.
class AppFitNotifierService {
  WebSocketChannel? _channel;
  WebSocket? _socket;
  StreamSubscription? _socketSubscription;

  // 재연결 관련
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 3;
  static const int _initialDelaySeconds = 3;
  static const int _maxDelaySeconds = 300;

  // Heartbeat (Ghost Connection 감지)
  Timer? _heartbeatTimer;
  static const Duration _heartbeatInterval = Duration(seconds: 60);
  DateTime? _lastMessageAt; // 마지막 메시지 수신 시각
  DateTime? _connectedAt;   // 연결 수립 시각

  // Race condition 방지
  bool _isConnecting = false;

  /// _handleDisconnection 중복 실행 방지 (heartbeat/onError/onDone 동시 호출 가드)
  bool _isHandlingDisconnection = false;

  /// dispose 이후 이벤트 처리 차단
  bool _isDisposed = false;

  // 연결 정보 캐시 (재연결용)
  String? _cachedShopCode;
  String? _cachedProjectId;
  String? _cachedApiKey;
  String? _cachedAesKey;

  // 현재 연결 상태
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  // 최초 연결 여부 추적 (initialConnected vs reconnected 구분)
  bool _hasEverConnected = false;

  // 연결된 매장 코드 (Getter)
  String? get cachedShopCode => _cachedShopCode;

  // 주문 알림 스트림 컨트롤러
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get stream => _controller.stream;

  // 연결 상태 스트림 컨트롤러
  final _connectionStateController = StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get connectionStateStream => _connectionStateController.stream;

  // Connectivity 구독
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // 로거
  final AppFitLogger _logger;

  AppFitNotifierService({AppFitLogger? logger})
      : _logger = logger ?? DefaultAppFitLogger();

  /// 리소스 해제
  ///
  /// WebSocket 리스너를 먼저 완전히 취소한 뒤 StreamController를 닫아
  /// "close 직후 add" 레이스를 방지합니다.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    await _cleanupConnection();

    // 캐시 정보 초기화
    _cachedShopCode = null;
    _cachedProjectId = null;
    _cachedApiKey = null;
    _cachedAesKey = null;
    _hasEverConnected = false;

    if (!_connectionStateController.isClosed) {
      await _connectionStateController.close();
    }
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  /// WebSocket 연결 시작 (파라미터 기반)
  Future<void> connect({
    required String shopCode,
    required String projectId,
    required String apiKey,
    required String aesKey,
  }) async {
    if (_isDisposed) {
      await _logger.log('[Notifier] dispose 이후 connect 무시');
      return;
    }

    // 이미 같은 정보로 연결되어 있다면 무시
    if (_isConnected && _cachedShopCode == shopCode && _channel != null) {
      await _logger.log('[Notifier] 이미 연결되어 있습니다. (Shop: $shopCode)');
      return;
    }

    // 정보 캐싱 (재연결 시 사용)
    _cachedShopCode = shopCode;
    _cachedProjectId = projectId;
    _cachedApiKey = apiKey;
    _cachedAesKey = aesKey;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();

    // Connectivity 리스너 시작 (이전 구독 완전 정리 후 재등록)
    await _initConnectivityListener();

    await _connectInternal();
  }

  /// 내부 연결 로직 (Race condition 방지)
  Future<void> _connectInternal() async {
    if (_isDisposed) return;
    if (_isConnecting) return; // 중복 연결 시도 차단
    _isConnecting = true;

    // 기존 연결 정리
    await _cleanupConnection();

    if (_cachedShopCode == null ||
        _cachedProjectId == null ||
        _cachedApiKey == null ||
        _cachedAesKey == null) {
      await _logger.error('[Notifier] 연결 정보가 부족하여 연결할 수 없습니다.', null);
      _isConnecting = false;
      return;
    }

    try {
      // 1. WebSocket URL 생성
      final baseUrl = AppFitConfig.websocketUrl;
      final wssUrl = '$baseUrl/ws';

      await _logger.log('[Notifier] 연결 시도: $wssUrl');

      // 2. API Key 암호화 & 헤더 준비
      final encryptedApiKey =
          CryptoUtils.encryptAesGcm(_cachedApiKey!, _cachedAesKey!);

      // dart:io WebSocket을 사용하여 헤더 설정
      final socket = await WebSocket.connect(
        wssUrl,
        headers: {
          'Authorization': 'Bearer $encryptedApiKey',
          'X-Waldlust-ProjectId': _cachedProjectId!,
          'X-Waldlust-ShopCode': _cachedShopCode!,
          'Origin': baseUrl, // 브라우저 동작 모방을 위해 Origin 추가
        },
      ).timeout(const Duration(seconds: 10));

      // 프로토콜 레벨 ping/pong (서버가 pong 미응답 시 onDone 자동 발화)
      socket.pingInterval = const Duration(seconds: 25);

      // 3. 소켓 및 채널 저장
      _socket = socket;
      _channel = IOWebSocketChannel(socket);
      _isConnecting = false;
      _isConnected = true;
      _connectedAt = DateTime.now();
      _lastMessageAt = null;
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();  // 연결 성공 시 예약된 재연결 타이머 취소
      _reconnectTimer = null;

      // 초기 연결 vs 재연결 구분 emit
      if (_hasEverConnected) {
        _safeAddConnectionState(ConnectionStatus.reconnected);
      } else {
        _hasEverConnected = true;
        _safeAddConnectionState(ConnectionStatus.initialConnected);
      }
      _startHeartbeat();
      await _logger.log('[Notifier] 연결 성공');

      // 4. 리스너 등록
      _socketSubscription = _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (error) {
          _logger.error('[Notifier] 소켓 에러', error);
          _handleDisconnection();
        },
        onDone: () {
          _logger.log('[Notifier] 소켓 연결 종료됨');
          _handleDisconnection();
        },
        cancelOnError: true,
      );
    } catch (e) {
      await _logger.error('[Notifier] 연결 실패', e);
      _isConnecting = false;
      _handleDisconnection();
    }
  }

  /// Heartbeat 시작 (Ghost Connection 감지)
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _logger.log('[Notifier] Heartbeat 시작 (간격: ${_heartbeatInterval.inSeconds}초)');
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) async {
      final readyState = _socket?.readyState;
      final readyStateName = _readyStateName(readyState);
      final now = DateTime.now();

      // 연결 지속 시간
      final connectedDuration =
          _connectedAt != null ? now.difference(_connectedAt!) : null;
      final connectedDurationStr = connectedDuration != null
          ? '${connectedDuration.inMinutes}분 ${connectedDuration.inSeconds % 60}초'
          : '알 수 없음';

      // 마지막 메시지 경과 시간
      final sinceLastMessage =
          _lastMessageAt != null ? now.difference(_lastMessageAt!) : null;
      final sinceLastMessageStr = sinceLastMessage != null
          ? '${sinceLastMessage.inMinutes}분 ${sinceLastMessage.inSeconds % 60}초 전'
          : '수신 기록 없음';

      if (readyState == null || readyState != WebSocket.open) {
        // 비정상 — 프로덕션에서도 반드시 로깅 (재연결 진입 사유)
        await _logger.log(
          '[Notifier] Heartbeat: 연결 끊김 감지 → 재연결 '
          '(readyState: $readyStateName, 연결유지: $connectedDurationStr, 마지막수신: $sinceLastMessageStr)',
        );
        _handleDisconnection();
      } else {
        // 정상 heartbeat 로그는 디버그 빌드에서만 출력 (프로덕션 노이즈 억제)
        if (kDebugMode) {
          await _logger.log(
            '[Notifier] Heartbeat: 정상 '
            '(readyState: $readyStateName, 연결유지: $connectedDurationStr, 마지막수신: $sinceLastMessageStr)',
          );
        }

        // Ghost Connection 경고: 5분 이상 메시지 없음
        if (sinceLastMessage != null && sinceLastMessage.inMinutes >= 5) {
          /*await _logger.log(
            '[Notifier] ⚠️ Ghost Connection 의심: ${sinceLastMessage.inMinutes}분간 메시지 없음 '
            '(readyState는 open이지만 데이터 수신 없음)',
          );*/
        }
      }
    });
  }

  /// readyState 숫자를 이름 문자열로 변환
  String _readyStateName(int? state) {
    switch (state) {
      case WebSocket.connecting:
        return 'connecting(0)';
      case WebSocket.open:
        return 'open(1)';
      case WebSocket.closing:
        return 'closing(2)';
      case WebSocket.closed:
        return 'closed(3)';
      case null:
        return 'null(소켓 없음)';
      default:
        return 'unknown($state)';
    }
  }

  /// Heartbeat 중지
  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// dispose 후 add 방지
  void _safeAddConnectionState(ConnectionStatus status) {
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(status);
    }
  }

  /// 메시지 처리
  void _handleMessage(dynamic message) {
    if (_isDisposed) return;
    _lastMessageAt = DateTime.now();
    try {
      final decoded = jsonDecode(message as String);
      _logger.log('[Notifier] 메시지 수신: ${_formatSocketMessage(decoded)}');

      if (decoded is Map<String, dynamic>) {
        // 에러 메시지 처리
        if (decoded['type'] == 'error') {
          _logger.error('[Notifier] 서버 에러 수신: ${decoded['error']}', null);
          return;
        }

        // 정상 이벤트 전파
        if (!_controller.isClosed) {
          _controller.add(decoded);
        }
      }
    } catch (e) {
      _logger.error('[Notifier] 메시지 파싱 실패', e);
    }
  }

  /// 연결 끊김 처리 및 재연결 스케줄링
  ///
  /// heartbeat/onError/onDone에서 동시 호출되어도 가드로 한 번만 실행됩니다.
  void _handleDisconnection() {
    if (_isDisposed) return;
    if (_isHandlingDisconnection) return;
    _isHandlingDisconnection = true;

    // cleanup은 fire-and-forget — 콜백 컨텍스트(void)에서 호출되므로 await 불가
    // cancel/close 진행 중에도 _isDisposed·isClosed 가드로 후속 처리 안전
    // ignore: unawaited_futures
    _cleanupConnection().whenComplete(() {
      _isConnected = false;
      _safeAddConnectionState(ConnectionStatus.reconnecting);
      _scheduleReconnect();
      _isHandlingDisconnection = false;
    });
  }

  /// 재연결 스케줄링 (Exponential Backoff)
  void _scheduleReconnect() {
    if (_isDisposed) return;
    if (_cachedShopCode == null) return; // 연결 정보 없으면 재연결 불가

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _logger.error('[Notifier] 최대 재연결 횟수 초과. 네트워크 복원 대기.', null);
      _safeAddConnectionState(ConnectionStatus.disconnected);
      return;
    }

    final delaySeconds = min(
      _initialDelaySeconds *
          pow(2, _reconnectAttempts).toInt(), // 3→6→12→24→...
      _maxDelaySeconds, // 최대 300초(5분)
    );
    _reconnectAttempts++;
    _logger.log('[Notifier] $_reconnectAttempts번째 재연결 예약 (${delaySeconds}초 후)');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      _connectInternal();
    });
  }

  /// Connectivity 리스너 초기화 (내부)
  ///
  /// 이전 구독의 cancel을 반드시 await하여 listener 중복 등록을 방지합니다.
  Future<void> _initConnectivityListener() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;

    if (_isDisposed) return;

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
      (results) {
        if (_cachedShopCode == null) return; // intentional disconnect 후 무시
        final hasConnection = results.any(
          (r) =>
              r == ConnectivityResult.wifi ||
              r == ConnectivityResult.mobile ||
              r == ConnectivityResult.ethernet,
        );
        if (hasConnection && !_isConnected) {
          notifyNetworkRestored();
        }
      },
    );
  }

  /// 네트워크 복원 감지 시 backoff 초기화 후 즉시 재연결
  ///
  /// 외부에서도 호출 가능 (앱이 직접 트리거할 경우)
  void notifyNetworkRestored() {
    if (_isDisposed) return;
    if (_cachedShopCode == null) return;
    if (_isConnected || _isConnecting) return;  // 연결 시도 중에도 무시
    _logger.log('[Notifier] 네트워크 복원 → backoff 초기화 후 즉시 재연결');
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _scheduleReconnect();
  }

  /// 연결 자원 정리
  ///
  /// socket subscription cancel을 await하여 후속 메시지 유입 차단.
  Future<void> _cleanupConnection() async {
    _stopHeartbeat();
    _connectedAt = null;
    final sub = _socketSubscription;
    _socketSubscription = null;
    await sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _socket = null;
    _isConnected = false;
  }

  /// 완전한 연결 종료 (로그아웃 등)
  Future<void> disconnect() async {
    _logger.log('[Notifier] 서비스 종료 (Disconnect)');
    _reconnectTimer?.cancel();
    await _connectivitySubscription?.cancel(); // connectivity 리스너 정리
    _connectivitySubscription = null;
    await _cleanupConnection();
    _safeAddConnectionState(ConnectionStatus.disconnected); // 명시적 종료 알림

    // 캐시 정보 초기화
    _cachedShopCode = null;
    _cachedProjectId = null;
    _cachedApiKey = null;
    _cachedAesKey = null;
    _hasEverConnected = false;
  }

  /// 소켓 메시지를 읽기 좋은 멀티라인 map 형식으로 포맷
  String _formatSocketMessage(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) return decoded.toString();
    final eventType = decoded['eventType'] as String?
        ?? decoded['@type'] as String?
        ?? '?';
    final payload = decoded['payload'] as Map<String, dynamic>?;
    if (payload == null) return eventType;

    final buf = StringBuffer('\n');
    void row(String key, dynamic value) =>
        buf.writeln('  ${key.padRight(11)}: $value');

    row('type', eventType);

    final shopName = payload['shopName'];
    if (shopName != null) row('shop', shopName);

    final userId = payload['userId'];
    if (userId != null) row('userId', userId);

    final orderSource = payload['orderSource'];
    if (orderSource != null) row('source', orderSource);

    final orderNo = payload['orderNo'];
    if (orderNo != null) row('orderNo', orderNo);

    final displayNo = payload['displayOrderNo'];
    final shopNo = payload['shopOrderNo'];
    if (displayNo != null) row('displayNo', '#$displayNo');
    if (shopNo != null) row('shopNo', shopNo);

    final orderName = payload['orderName'];
    if (orderName != null) row('orderName', orderName);

    final totalAmount = payload['totalAmount'];
    if (totalAmount != null) row('amount', '$totalAmount');

    final readyTime = payload['readyTime'];
    if (readyTime != null) row('readyTime', '${readyTime}min');

    final orderAction = payload['orderAction'];
    if (orderAction != null) row('orderAction', orderAction);

    final message = payload['message'];
    if (message != null) row('message', message);

    final createdAt = payload['createdAt'];
    if (createdAt != null) row('createdAt', createdAt);

    final orderLines = payload['orderLines'];
    if (orderLines is List && orderLines.isNotEmpty) {
      buf.writeln('  lines       :');
      for (var i = 0; i < orderLines.length; i++) {
        final line = orderLines[i];
        if (line is! Map<String, dynamic>) continue;
        final posId = line['posId'] as String? ?? '?';
        final itemName = line['itemName'] as String? ?? '?';
        final qty = line['qty'];
        buf.writeln('    [${i + 1}][$posId] $itemName x$qty');
        final options = line['options'];
        if (options is List && options.isNotEmpty) {
          for (final opt in options.whereType<Map<String, dynamic>>()) {
            final optPosId = opt['posId'] as String? ?? '?';
            final optName = opt['optionName'] as String? ?? '?';
            final optQty = opt['qty'] ?? 1;
            buf.writeln('         [$optPosId] $optName x$optQty');
          }
        }
      }
    }

    return buf.toString().trimRight();
  }
}
