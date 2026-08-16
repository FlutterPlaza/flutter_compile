import 'dart:io';

import 'package:flutter_compile/src/shared/atomic_file_write.dart';

const String kDefaultAndroidCodePushYamlPath =
    'android/app/src/main/assets/codepush.yaml';

/// True when [releaseVersion] can be stamped into codepush.yaml and
/// matched by devices. The SINGLE charset predicate — shared with the
/// release command's pre-flight validation so the pre-check cannot
/// silently diverge from the ArgumentError below it exists to
/// prevent.
bool isStampableReleaseVersion(String releaseVersion) =>
    RegExp(r'^[A-Za-z0-9._+\-]+$').hasMatch(releaseVersion);

/// Stamps [releaseVersion] into the Android code push config asset so the
/// built APK carries the version it is released as. Returns the original
/// file content for restoring afterwards, or `null` when the file does not
/// exist (code push has not been initialized for Android).
String? writeReleaseVersionToAndroidYaml(
  String releaseVersion, {
  String yamlPath = kDefaultAndroidCodePushYamlPath,
}) {
  if (!isStampableReleaseVersion(releaseVersion)) {
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
  _atomicWrite(yamlPath, content);
  return originalContent;
}

void restoreAndroidYaml(
  String originalContent, {
  String yamlPath = kDefaultAndroidCodePushYamlPath,
}) {
  _atomicWrite(yamlPath, originalContent);
}

/// Delegates to [atomicReplaceFileContents]. The site-specific
/// constraint: the target lives under src/main/assets/, which
/// Gradle packages wholesale — the helper's dot-prefixed temps fall
/// under AAPT's default ignoreAssetsPattern, so a leftover (kill
/// between write and rename) can never ship in the APK. The
/// helper's symlink resolution also means a checkout that symlinks
/// codepush.yaml to shared config keeps its wiring through the
/// stamp/restore cycle, matching the iOS Info.plist writer.
void _atomicWrite(String path, String content) =>
    atomicReplaceFileContents(path, content);
