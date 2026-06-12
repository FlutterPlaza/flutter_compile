import 'dart:io';

const String kDefaultAndroidCodePushYamlPath =
    'android/app/src/main/assets/codepush.yaml';

/// Stamps [releaseVersion] into the Android code push config asset so the
/// built APK carries the version it is released as. Returns the original
/// file content for restoring afterwards, or `null` when the file does not
/// exist (code push has not been initialized for Android).
String? writeReleaseVersionToAndroidYaml(
  String releaseVersion, {
  String yamlPath = kDefaultAndroidCodePushYamlPath,
}) {
  if (!RegExp(r'^[A-Za-z0-9._+\-]+$').hasMatch(releaseVersion)) {
    throw ArgumentError.value(
      releaseVersion,
      'releaseVersion',
      'contains characters that would break the YAML config',
    );
  }

  final yamlFile = File(yamlPath);
  if (!yamlFile.existsSync()) return null;

  final originalContent = yamlFile.readAsStringSync();
  var content = originalContent;
  final versionLine = 'release_version: "$releaseVersion"';

  if (RegExp(r'^release_version:', multiLine: true).hasMatch(content)) {
    content = content.replaceFirst(
      RegExp(r'^release_version:.*$', multiLine: true),
      versionLine,
    );
  } else {
    if (content.isNotEmpty && !content.endsWith('\n')) content += '\n';
    content += '$versionLine\n';
  }

  // Write to a temp file and rename over the original: a failed write
  // (disk full, permissions) can then never corrupt the config, and the
  // original error propagates without a doomed in-place rescue attempt.
  final tempFile = File('$yamlPath.tmp');
  try {
    tempFile.writeAsStringSync(content);
    tempFile.renameSync(yamlPath);
  } on FileSystemException {
    try {
      tempFile.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup; the original config is untouched either way.
    }
    rethrow;
  }
  return originalContent;
}

void restoreAndroidYaml(
  String originalContent, {
  String yamlPath = kDefaultAndroidCodePushYamlPath,
}) {
  File(yamlPath).writeAsStringSync(originalContent);
}
