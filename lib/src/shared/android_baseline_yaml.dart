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

  yamlFile.writeAsStringSync(content);
  return originalContent;
}

void restoreAndroidYaml(
  String originalContent, {
  String yamlPath = kDefaultAndroidCodePushYamlPath,
}) {
  File(yamlPath).writeAsStringSync(originalContent);
}
