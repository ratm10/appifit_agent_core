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

  /// 일부 필드를 교체한 새 인스턴스 반환.
  UpdateInfo copyWith({
    int? currentVersion,
    int? latestVersion,
    String? downloadUrl,
    bool? hasUpdate,
  }) {
    return UpdateInfo(
      currentVersion: currentVersion ?? this.currentVersion,
      latestVersion: latestVersion ?? this.latestVersion,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      hasUpdate: hasUpdate ?? this.hasUpdate,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UpdateInfo &&
        other.currentVersion == currentVersion &&
        other.latestVersion == latestVersion &&
        other.downloadUrl == downloadUrl &&
        other.hasUpdate == hasUpdate;
  }

  @override
  int get hashCode =>
      Object.hash(currentVersion, latestVersion, downloadUrl, hasUpdate);

  @override
  String toString() =>
      'UpdateInfo(current=$currentVersion, latest=$latestVersion, hasUpdate=$hasUpdate, url=$downloadUrl)';
}

/// 다운로드 진행 이벤트 전달 객체
class OtaDownloadEvent {
  final OtaStatusType status;
  final double progress;

  const OtaDownloadEvent({required this.status, required this.progress});

  /// 일부 필드를 교체한 새 인스턴스 반환.
  OtaDownloadEvent copyWith({OtaStatusType? status, double? progress}) {
    return OtaDownloadEvent(
      status: status ?? this.status,
      progress: progress ?? this.progress,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OtaDownloadEvent &&
        other.status == status &&
        other.progress == progress;
  }

  @override
  int get hashCode => Object.hash(status, progress);

  @override
  String toString() =>
      'OtaDownloadEvent(status: ${status.name}, progress: $progress)';
}
