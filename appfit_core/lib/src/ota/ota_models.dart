/// OTA 업데이트 상태 이벤트 타입
enum OtaStatusType { idle, downloading, readyToInstall, installing, error }

/// 앱 버전 정보 메타 모델
class UpdateInfo {
  final int currentVersion;
  final int latestVersion;
  final String downloadUrl;
  final bool hasUpdate;

  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
    required this.hasUpdate,
  });

  @override
  String toString() =>
      'UpdateInfo(current=$currentVersion, latest=$latestVersion, hasUpdate=$hasUpdate, url=$downloadUrl)';
}

/// 다운로드 진행 이벤트 전달 객체
class OtaDownloadEvent {
  final OtaStatusType status;
  final double progress;

  const OtaDownloadEvent({required this.status, required this.progress});
}
