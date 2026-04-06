import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_downloader/flutter_downloader.dart';
import 'package:app_installer/app_installer.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';
import '../config/appfit_timeouts.dart';
import 'ota_models.dart';

/// AppFit 코어용 OTA 업데이트 관리자
/// [OtaUpdateManager] 싱글톤 인스턴스를 통해 호출합니다.
class OtaUpdateManager {
  static final OtaUpdateManager _instance = OtaUpdateManager._internal();
  factory OtaUpdateManager() => _instance;
  OtaUpdateManager._internal();

  bool _isInitialized = false;
  Timer? _pollingTimer;
  String? _taskId;
  String? _apkPath;
  OtaStatusType _status = OtaStatusType.idle;
  double _progress = 0.0;

  // 상태 변경 콜백
  Function(OtaStatusType status, double progress)? _onStatusChanged;
  Function(String error)? _onError;
  VoidCallback? _onDone;

  /// 초기화
  Future<void> initialize() async {
    if (_isInitialized) return;
    await FlutterDownloader.initialize(debug: false, ignoreSsl: true);
    _isInitialized = true;
    debugPrint('[OtaUpdateManager] 초기화 완료');
  }

  /// 버전 체크
  Future<UpdateInfo?> checkForUpdate({
    required String versionUrl,
    required String downloadUrl,
    int timeoutSeconds = AppFitTimeouts.connectTimeoutSeconds,
  }) async {
    try {
      if (!_isInitialized) await initialize();

      final packageInfo = await PackageInfo.fromPlatform();
      final current = int.tryParse(packageInfo.buildNumber) ?? 0;

      final dio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: timeoutSeconds),
        receiveTimeout: Duration(seconds: timeoutSeconds),
      ));

      final response = await dio.get(versionUrl);
      final server = (response.data['version'] as num).toInt();

      debugPrint('[OtaUpdateManager] 버전 체크: 현재=$current, 서버=$server');

      return UpdateInfo(
        currentVersion: current,
        latestVersion: server,
        downloadUrl: downloadUrl,
        hasUpdate: server > current,
      );
    } catch (e, s) {
      debugPrint('[OtaUpdateManager] 버전 체크 실패: $e\n$s');
      return null;
    }
  }

  /// 다운로드 실행 및 설치
  Future<void> executeUpdate({
    required String downloadUrl,
    required String destinationFilename,
    required void Function(OtaStatusType status, double progress) onStatus,
    required void Function(String error) onError,
    VoidCallback? onDone,
  }) async {
    try {
      if (!_isInitialized) await initialize();

      // 저장 경로 결정
      Directory? dir;
      if (Platform.isAndroid) {
        // 호환성을 위해 ApplicationSupportDirectory 사용권장이나 기존 방식 고려 (GetTemporary 또는 Support)
        dir = await getApplicationSupportDirectory();
      } else {
        dir = await getTemporaryDirectory();
      }

      _apkPath = '${dir.path}/$destinationFilename';

      // 기존 파일 삭제
      final file = File(_apkPath!);
      if (await file.exists()) await file.delete();

      _status = OtaStatusType.downloading;
      _progress = 0.0;

      _onStatusChanged = onStatus;
      _onDone = onDone;
      _onError = onError;

      // 상태 초기화 콜백
      onStatus(OtaStatusType.downloading, 0.0);

      _taskId = await FlutterDownloader.enqueue(
        url: downloadUrl,
        savedDir: dir.path,
        fileName: destinationFilename,
        showNotification: true,
        openFileFromNotification: false,
      );

      debugPrint(
          '[OtaUpdateManager] 다운로드 시작: taskId=$_taskId, destination=$_apkPath');

      _startPolling(onStatus: onStatus, onError: onError, onDone: onDone);
    } catch (e, s) {
      debugPrint('[OtaUpdateManager] executeUpdate 실패: $e\n$s');
      onError(e.toString());
    }
  }

  /// 0.5초 다운로드 폴링
  void _startPolling({
    required void Function(OtaStatusType status, double progress) onStatus,
    required void Function(String error) onError,
    VoidCallback? onDone,
  }) {
    _pollingTimer?.cancel();
    int runningAt100Count = 0;

    Future<void> _triggerInstall() async {
      _pollingTimer?.cancel();
      _status = OtaStatusType.readyToInstall;
      debugPrint('[OtaUpdateManager] 다운로드 완료 -> readyToInstall');
      onStatus(OtaStatusType.readyToInstall, 1.0);
      await install(onDone: onDone, onError: onError);
    }

    _pollingTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) async {
        if (_taskId == null) return;
        try {
          final tasks = await FlutterDownloader.loadTasksWithRawQuery(
            query: "SELECT * FROM task WHERE task_id='$_taskId'",
          );

          // 태스크가 DB에서 사라진 경우: 100% 이후 완료된 것으로 간주
          if (tasks == null || tasks.isEmpty) {
            if (_progress >= 1.0 && _status == OtaStatusType.downloading) {
              debugPrint('[OtaUpdateManager] 태스크 소멸 감지 (100% 완료로 처리)');
              await _triggerInstall();
            }
            return;
          }

          final task = tasks.first;
          final progress = task.progress.clamp(0, 100) / 100.0;
          _progress = progress;

          // running 중인 상태 리포트
          if (task.status == DownloadTaskStatus.running) {
            onStatus(OtaStatusType.downloading, progress);

            // running 상태로 100%가 지속되면 complete로 처리 (일부 Android 기기 대응)
            if (progress >= 1.0) {
              runningAt100Count++;
              if (runningAt100Count >= 4) {
                debugPrint('[OtaUpdateManager] running 100% 지속 → complete 처리');
                await _triggerInstall();
              }
            } else {
              runningAt100Count = 0;
            }
          } else {
            runningAt100Count = 0;
          }

          if (task.status == DownloadTaskStatus.complete) {
            await _triggerInstall();
          } else if (task.status == DownloadTaskStatus.failed ||
              task.status == DownloadTaskStatus.canceled) {
            _pollingTimer?.cancel();
            _status = OtaStatusType.error;
            onError('다운로드 실패 (status: ${task.status})');
          }
        } catch (e) {
          debugPrint('[OtaUpdateManager] 폴링 오류: $e');
        }
      },
    );
  }

  /// APK 설치
  Future<void> install({
    VoidCallback? onDone,
    Function(String error)? onError,
  }) async {
    if (_apkPath == null) return;
    _status = OtaStatusType.installing;
    debugPrint('[OtaUpdateManager] 설치 시작: $_apkPath');
    try {
      if (_onStatusChanged != null) {
        _onStatusChanged!(OtaStatusType.installing, 1.0);
      }
      await AppInstaller.installApk(_apkPath!);
      onDone?.call();
      _onDone?.call();
    } catch (e) {
      debugPrint('[OtaUpdateManager] 설치 실패: $e');
      onError?.call(e.toString());
      _onError?.call(e.toString());
    }
  }

  /// 다운로드/업데이트 취소
  void cancelUpdate() {
    _pollingTimer?.cancel();
    if (_taskId != null) {
      FlutterDownloader.cancel(taskId: _taskId!);
    }
    _taskId = null;
    _apkPath = null;
    _status = OtaStatusType.idle;
    _progress = 0.0;
    _onStatusChanged = null;
    _onDone = null;
    _onError = null;
    debugPrint('[OtaUpdateManager] 업데이트 취소됨');
  }

  /// 리소스 등 정리
  void dispose() {
    cancelUpdate();
  }
}
