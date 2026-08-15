import 'dart:io';

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

/// Writes [content] to [path] via a pid-qualified temp file and an atomic
/// rename, so a failed or concurrent write can never leave the target
/// truncated.
void _atomicWrite(String path, String content) {
  // Dot-prefixed BASENAME: the target lives under src/main/assets/,
  // which Gradle packages wholesale, and AAPT's default
  // ignoreAssetsPattern excludes dotfiles — a leftover temp (kill
  // between write and rename, or a failed cleanup) must not ship in
  // the APK. Same directory keeps the rename atomic.
  final dir = File(path).parent.path;
  final base = path.split(Platform.pathSeparator).last;
  final tempFile = File('$dir${Platform.pathSeparator}.$base.$pid.tmp');
  try {
    tempFile.writeAsStringSync(content);
    tempFile.renameSync(path);
  } on FileSystemException {
    try {
      tempFile.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup; the target file is untouched either way.
    }
    rethrow;
  }
}
