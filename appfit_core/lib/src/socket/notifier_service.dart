import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:appfit_core/src/auth/crypto_utils.dart';
import 'package:appfit_core/src/config/appfit_config.dart';
import 'package:appfit_core/src/config/appfit_timeouts.dart';
import 'package:appfit_core/src/logging/appfit_logger.dart';

/// WebSocket 연결 상태
enum ConnectionStatus {
  connected, // 정상 연결됨 (초기 연결 또는 재연결 구분 없이 범용)
  initialConnected, // 첫 연결 성공 (앱 시작/로그인 후 최초)
  reconnected, // 재연결 성공 (끊김 후 복구)
  reconnecting, // 재연결 시도 중 (backoff 대기 포함)
  disconnected, // 연결 끊김 (최대 재연결 횟수 초과 또는 의도적 종료)
}

/// ConnectionStatus 확장 - 연결됨 상태 편의 getter
extension ConnectionStatusExtension on ConnectionStatus {
  /// connected, initialConnected, reconnected 중 하나이면 true
  bool get isConnected =>
      this == ConnectionStatus.connected ||
      this == ConnectionStatus.initialConnected ||
      this == ConnectionStatus.reconnected;
}

/// WebSocket 연결 함수 시그니처.
///
/// 테스트에서 실제 네트워크 없이 재연결 상태머신을 검증할 수 있도록
/// [AppFitNotifierService] 생성자에 선택적으로 주입하는 seam 입니다.
/// 기본 구현은 [WebSocket.connect] 와 100% 동일하게 동작합니다.
typedef AppFitWebSocketConnector = Future<WebSocket> Function(
  String url,
  Map<String, dynamic> headers,
);

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

  /// 짧은 백오프(3→6→12→24→48초)로 빠르게 재시도하는 횟수.
  ///
  /// 이 횟수를 소진해도 **포기하지 않는다** — [_maxDelaySeconds] 간격의 느린
  /// 재시도로 넘어갈 뿐이다. 이전에는 여기서 완전히 멈췄고, 링크는 살아 있고
  /// 상위 경로만 죽는 장애에서는 connectivity 이벤트가 오지 않아 앱 재시작
  /// 전까지 실시간 수신이 영구히 끊겼다.
  static const int _fastReconnectAttempts = 5;
  static const int _initialDelaySeconds = 3;
  static const int _maxDelaySeconds = 300;

  /// 빠른 재시도를 모두 소진해 느린 재시도 구간에 들어간 상태.
  ///
  /// 이 구간에서는 상태를 [ConnectionStatus.disconnected] 로 고정한다
  /// (매 시도마다 reconnecting↔disconnected 를 반복하면 앱 UI 가 5분마다
  /// 깜빡이고 모니터링의 flapping 감지가 오탐한다).
  bool _isInSlowRetry = false;

  // Heartbeat (Ghost Connection 감지)
  Timer? _heartbeatTimer;
  static const Duration _heartbeatInterval = Duration(seconds: 60);
  DateTime? _lastMessageAt; // 마지막 메시지 수신 시각
  DateTime? _connectedAt; // 연결 수립 시각

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
  final _connectionStateController =
      StreamController<ConnectionStatus>.broadcast();
  Stream<ConnectionStatus> get connectionStateStream =>
      _connectionStateController.stream;

  // Connectivity 구독
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // 로거
  final AppFitLogger _logger;

  /// WebSocket 연결 함수 — 기본값은 [WebSocket.connect] 와 동일 (테스트 주입용 seam)
  final AppFitWebSocketConnector _connector;

  AppFitNotifierService({
    AppFitLogger? logger,
    AppFitWebSocketConnector? connector,
  })  : _logger = logger ?? DefaultAppFitLogger(),
        _connector = connector ?? _defaultConnector;

  static Future<WebSocket> _defaultConnector(
    String url,
    Map<String, dynamic> headers,
  ) =>
      WebSocket.connect(url, headers: headers);

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
    _isInSlowRetry = false;
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
      final socket = await _connector(
        wssUrl,
        {
          'Authorization': 'Bearer $encryptedApiKey',
          'X-Waldlust-ProjectId': _cachedProjectId!,
          'X-Waldlust-ShopCode': _cachedShopCode!,
          'Origin': baseUrl, // 브라우저 동작 모방을 위해 Origin 추가
        },
      ).timeout(AppFitTimeouts.wsConnectTimeout);

      // 프로토콜 레벨 ping/pong (서버가 pong 미응답 시 onDone 자동 발화)
      socket.pingInterval = AppFitTimeouts.wsPingInterval;

      // 3. 소켓 및 채널 저장
      _socket = socket;
      _channel = IOWebSocketChannel(socket);
      _isConnecting = false;
      _isConnected = true;
      _connectedAt = DateTime.now();
      _lastMessageAt = null;
      final recoveredAfterAttempts = _isInSlowRetry ? _reconnectAttempts : null;
      _reconnectAttempts = 0;
      _isInSlowRetry = false;
      _reconnectTimer?.cancel(); // 연결 성공 시 예약된 재연결 타이머 취소
      _reconnectTimer = null;

      // 초기 연결 vs 재연결 구분 emit
      if (_hasEverConnected) {
        _safeAddConnectionState(ConnectionStatus.reconnected);
      } else {
        _hasEverConnected = true;
        _safeAddConnectionState(ConnectionStatus.initialConnected);
      }
      _startHeartbeat();
      // 느린 재시도에서 복귀한 경우는 시도 횟수를 함께 남긴다 — 장시간 단절이
      // 자력 복구됐다는(= 2단계 백오프가 실제로 동작했다는) 유일한 증거다.
      await _logger.log(
        recoveredAfterAttempts == null
            ? '[Notifier] 연결 성공'
            : '[Notifier] 연결 성공 (느린 재시도 $recoveredAfterAttempts번째 시도에서 복구)',
      );

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
    _logger
        .log('[Notifier] Heartbeat 시작 (간격: ${_heartbeatInterval.inSeconds}초)');
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
          '[Notifier] Heartbeat: 연결 끊김 감지 -> 재연결 '
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

        // Ghost Connection 경고: 일정 시간 이상 메시지 없음
        if (sinceLastMessage != null &&
            sinceLastMessage >= AppFitTimeouts.ghostConnectionThreshold) {
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
      // 느린 재시도 구간에서는 disconnected 를 유지한다 — 5분마다
      // reconnecting 으로 되돌리면 UI 가 깜빡이고 flapping 감지가 오탐한다.
      if (!_isInSlowRetry) {
        _safeAddConnectionState(ConnectionStatus.reconnecting);
      }
      _scheduleReconnect();
      _isHandlingDisconnection = false;
    });
  }

  /// 재연결 스케줄링 (2단계 백오프)
  ///
  /// 1단계(빠름): 3→6→12→24→48초, 누적 93초. 순단·서버 재시작 등 대부분의
  /// 끊김은 여기서 복구된다.
  /// 2단계(느림): 이후 [_maxDelaySeconds] 간격으로 **무한** 재시도. 전환 시점에
  /// 한 번만 [ConnectionStatus.disconnected] 를 알려 앱이 "장시간 끊김" UI
  /// (수동 재연결 어포던스 포함)를 띄울 수 있게 한다.
  void _scheduleReconnect() {
    if (_isDisposed) return;
    if (_cachedShopCode == null) return; // 연결 정보 없으면 재연결 불가

    final int delaySeconds;
    if (_reconnectAttempts >= _fastReconnectAttempts) {
      if (!_isInSlowRetry) {
        _isInSlowRetry = true;
        _logger.error(
          '[Notifier] 빠른 재연결 $_fastReconnectAttempts회 실패 '
          '— $_maxDelaySeconds초 간격 재시도로 전환 (계속 시도함)',
          null,
        );
        _safeAddConnectionState(ConnectionStatus.disconnected);
      }
      // 느린 구간은 pow 를 쓰지 않는다. 무한 재시도에서 지수가 계속 커지면
      // pow(2, 1024) 가 double.infinity 가 되어 toInt() 가 던진다(5분 간격이면
      // 약 3.5일 연속 다운에서 도달). 이 분기 덕에 아래 pow 의 지수는 항상
      // 4 이하로 묶인다.
      delaySeconds = _maxDelaySeconds;
    } else {
      delaySeconds = min(
        _initialDelaySeconds *
            pow(2, _reconnectAttempts).toInt(), // 3→6→12→24→48
        _maxDelaySeconds,
      );
    }
    _reconnectAttempts++;
    _logger.log('[Notifier] $_reconnectAttempts번째 재연결 예약 ($delaySeconds초 후)');

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
    if (_isConnected || _isConnecting) return; // 연결 시도 중에도 무시
    _logger.log('[Notifier] 네트워크 복원 -> backoff 초기화 후 즉시 재연결');
    _reconnectAttempts = 0;
    _isInSlowRetry = false; // 다음 끊김에서 reconnecting 을 다시 알리기 위해 해제
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
    _reconnectAttempts = 0;
    _isInSlowRetry = false;
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

  /// 소켓 메시지를 한 줄 key=value 형식으로 요약.
  ///
  /// 운영 로그 가독성을 위해 핵심 필드만 단일 라인으로 출력한다.
  /// 메뉴는 `메뉴명 x수량(+옵션수)` 로 요약하며, 옵션 상세는 생략한다.
  String _formatSocketMessage(dynamic decoded) {
    if (decoded is! Map<String, dynamic>) return decoded.toString();
    final eventType =
        decoded['eventType'] as String? ?? decoded['@type'] as String? ?? '?';
    final payload = decoded['payload'] as Map<String, dynamic>?;
    if (payload == null) return eventType;

    final parts = <String>['type=$eventType'];
    void add(String key, dynamic value) {
      if (value != null) parts.add('$key=$value');
    }

    add('source', payload['orderSource']);
    add('orderNo', payload['orderNo']);
    final displayNo = payload['displayOrderNo'];
    if (displayNo != null) parts.add('displayNo=#$displayNo');
    add('shopNo', payload['shopOrderNo']);
    add('orderName', payload['orderName']);
    add('amount', payload['totalAmount']);
    final readyTime = payload['readyTime'];
    if (readyTime != null) parts.add('readyTime=${readyTime}min');
    add('action', payload['orderAction']);
    add('message', payload['message']);

    final orderLines = payload['orderLines'];
    if (orderLines is List && orderLines.isNotEmpty) {
      final items = <String>[];
      for (final line in orderLines.whereType<Map<String, dynamic>>()) {
        final itemName = line['itemName'] as String? ?? '?';
        final qty = line['qty'];
        final options = line['options'];
        final optCount =
            (options is List) ? options.whereType<Map>().length : 0;
        items.add(
            optCount > 0 ? '$itemName x$qty(+$optCount)' : '$itemName x$qty');
      }
      parts.add('items=[${items.join(', ')}]');
    }

    return parts.join(' ');
  }
}
