/// pubspec.yaml의 version을 AppFitConfig.packageVersion에 동기화하는 스크립트.
///
/// 사용법:
///   cd appfit_core && dart run tool/sync_version.dart
import 'dart:io';

void main() {
  final pubspec = File('pubspec.yaml');
  if (!pubspec.existsSync()) {
    stderr.writeln('pubspec.yaml을 찾을 수 없습니다. appfit_core 디렉터리에서 실행하세요.');
    exit(1);
  }

  // pubspec.yaml에서 version 추출
  final versionLine = pubspec
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('version:'), orElse: () => '');
  if (versionLine.isEmpty) {
    stderr.writeln('pubspec.yaml에서 version을 찾을 수 없습니다.');
    exit(1);
  }
  final version = versionLine.split(':').last.trim();

  // appfit_config.dart 업데이트
  final configFile = File('lib/src/config/appfit_config.dart');
  if (!configFile.existsSync()) {
    stderr.writeln('appfit_config.dart를 찾을 수 없습니다.');
    exit(1);
  }

  final original = configFile.readAsStringSync();
  final pattern = RegExp(
    r"static const String packageVersion = '[^']*';",
  );

  if (!pattern.hasMatch(original)) {
    stderr.writeln('appfit_config.dart에서 packageVersion 상수를 찾을 수 없습니다.');
    exit(1);
  }

  final updated = original.replaceFirst(
    pattern,
    "static const String packageVersion = '$version';",
  );

  if (original == updated) {
    stdout.writeln('이미 동기화됨: v$version');
    return;
  }

  configFile.writeAsStringSync(updated);
  stdout.writeln('packageVersion 동기화 완료: v$version');
}
