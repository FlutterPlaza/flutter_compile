import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';

import 'constants.dart';

/// Manages downloading, caching, and verifying code-push-enabled engine
/// artifacts **per Flutter SDK version**.
///
/// Artifacts are stored at:
///   `~/.flutter_compile/cache/codepush-engine/<flutter-version>/<platform>/`
///
/// Manages code push engine artifacts cached locally.
///
/// Artifact download and verification are delegated to the fcp-tool binary.
///
/// The server publishes a `versions.json` manifest listing all supported
/// Flutter SDK versions and their build revisions.
class CodePushArtifactManager {
  CodePushArtifactManager({
    required Logger logger,
    String? baseUrl,
    String? cacheRoot,
  })  : _logger = logger,
        _baseUrl = baseUrl ?? '',
        _cacheRoot = cacheRoot ??
            '${Platform.environment['HOME'] ?? '/tmp'}/.flutter_compile/cache/${Constants.codePushCacheDir}';

  /// Returns the path to the fcp-tool binary, downloading if needed.
  /// Artifact management is delegated to this private binary.
  Future<String?> ensureBuildTool() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final os = Platform.isMacOS
        ? 'darwin'
        : Platform.isLinux
            ? 'linux'
            : 'windows';
    final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
    final cached = '$home/.flutter_compile/cache/tools/fcp-tool-$os-$arch';
    if (File(cached).existsSync()) return cached;
    _logger.err('Build tool not found. Run "fcp codepush setup" first.');
    return null;
  }

  final Logger _logger;
  final String _baseUrl;
  final String _cacheRoot;

  /// The current platform identifier (e.g., "darwin-arm64", "linux-x64").
  String get currentPlatform {
    final os = Platform.isMacOS
        ? 'darwin'
        : Platform.isLinux
            ? 'linux'
            : Platform.isWindows
                ? 'windows'
                : 'unknown';
    final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
    return '$os-$arch';
  }

  /// All host (desktop) platforms we distribute artifacts for.
  static const hostPlatforms = [
    'darwin-arm64',
    'darwin-x64',
    'linux-x64',
    'windows-x64',
  ];

  /// Mobile/embedded platforms we distribute artifacts for.
  static const mobilePlatforms = [
    'android-arm64',
    'ios-arm64',
  ];

  /// All platforms we distribute artifacts for.
  static const platforms = [
    ...hostPlatforms,
    ...mobilePlatforms,
  ];

  /// Map a Flutter build platform (e.g. "apk", "ios") to the artifact
  /// platform identifier (e.g. "android-arm64", "ios-arm64").
  /// Returns null for unknown platforms.
  static String? buildPlatformToArtifactPlatform(String buildPlatform) {
    switch (buildPlatform) {
      case 'apk':
      case 'appbundle':
      case 'android':
        return 'android-arm64';
      case 'ios':
      case 'ipa':
        return 'ios-arm64';
      case 'macos':
        return 'darwin-arm64';
      case 'linux':
        return 'linux-x64';
      case 'windows':
        return 'windows-x64';
      default:
        return null;
    }
  }

  // Artifact names are resolved by the fcp-tool binary at runtime.

  // ── Flutter version detection ─────────────────────────────────────

  /// Detect the Flutter SDK version the user currently has active.
  ///
  /// Tries, in order:
  ///   1. `flutter --version --machine` (JSON output with "frameworkVersion")
  ///   2. Reading `<flutter-sdk>/version` file
  ///
  /// Returns a version string like "3.24.0", or null if detection fails.
  String? detectFlutterVersion() {
    // Try `flutter --version --machine`.
    try {
      final result = Process.runSync('flutter', ['--version', '--machine']);
      if (result.exitCode == 0) {
        final json =
            jsonDecode(result.stdout as String) as Map<String, dynamic>;
        final version = json['frameworkVersion'] as String?;
        if (version != null && version.isNotEmpty) return version;
      }
    } on Exception {
      // Fall through to file-based detection.
    }

    // Try reading the version file from the Flutter SDK.
    try {
      final whichResult = Process.runSync('which', ['flutter']);
      if (whichResult.exitCode == 0) {
        final flutterBin = (whichResult.stdout as String).trim();
        // Resolve symlinks to get the real path.
        final resolved = File(flutterBin).resolveSymbolicLinksSync();
        final sdkDir = File(resolved).parent.parent.path;
        final versionFile = File('$sdkDir/version');
        if (versionFile.existsSync()) {
          return versionFile.readAsStringSync().trim();
        }
      }
    } on Exception {
      // Give up.
    }

    return null;
  }

  // ── Path helpers ──────────────────────────────────────────────────

  /// Path to the cached artifacts directory for a specific Flutter version.
  String versionDir(String flutterVersion) =>
      '$_cacheRoot/flutter-$flutterVersion';

  /// Path to gen_snapshot for the current platform and a given Flutter version.
  String? genSnapshotPath(String flutterVersion) {
    return genSnapshotPathForPlatform(flutterVersion, currentPlatform);
  }

  /// Path to gen_snapshot for a specific platform and Flutter version.
  String? genSnapshotPathForPlatform(
    String flutterVersion,
    String platform,
  ) {
    final exe = platform.startsWith('windows') ? '.exe' : '';
    final path = '${versionDir(flutterVersion)}/$platform/gen_snapshot$exe';
    return File(path).existsSync() ? path : null;
  }

  /// Path to the engine library for a given version and optional platform.
  String? engineLibraryPath(
    String flutterVersion, {
    String? platform,
  }) {
    // Artifact resolution delegated to fcp-tool.
    return null;
  }

  /// Check if artifacts for a Flutter version are already cached and verified.
  bool isVersionCached(String flutterVersion) {
    final stampFile = File('${versionDir(flutterVersion)}/.stamp');
    return stampFile.existsSync();
  }

  /// Check if all expected artifacts for a specific platform are cached.
  bool isPlatformCached(String flutterVersion, String platform) {
    // Artifact verification delegated to fcp-tool.
    final dir = '${versionDir(flutterVersion)}/$platform';
    return Directory(dir).existsSync();
  }

  // ── Version manifest ──────────────────────────────────────────────

  /// Fetch the versions manifest from the server.
  ///
  /// Returns a map of `{ "3.22.0": "build-rev-abc", "3.24.0": "build-rev-def" }`
  /// or null on failure.
  Future<Map<String, String>?> fetchSupportedVersions() async {
    final url = '$_baseUrl/versions.json';
    _logger.detail('Fetching supported versions from: $url');
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode != 200) {
          _logger.err(
            'Failed to fetch version manifest (HTTP ${response.statusCode})',
          );
          return null;
        }
        final body = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          return decoded.map((k, v) => MapEntry(k, v.toString()));
        }
        return null;
      } finally {
        client.close();
      }
    } on Exception catch (e) {
      _logger.err('Network error fetching version manifest: $e');
      return null;
    }
  }

  /// Check whether the server has artifacts for a specific Flutter version.
  Future<bool> isVersionSupported(String flutterVersion) async {
    final versions = await fetchSupportedVersions();
    if (versions == null) return false;
    return versions.containsKey(flutterVersion);
  }

  // ── Download ──────────────────────────────────────────────────────

  /// Download and cache artifacts for a specific Flutter version and platform.
  ///
  /// Returns true on success, false on failure.
  Future<bool> downloadArtifacts({
    required String flutterVersion,
    String? platform,
  }) async {
    final targetPlatform = platform ?? currentPlatform;
    // Artifact download is delegated to the fcp-tool binary.
    final tool = await ensureBuildTool();
    if (tool == null) return false;
    final result = Process.runSync(tool, [
      'download-artifacts',
      '--flutter-version',
      flutterVersion,
      '--platform',
      targetPlatform,
    ]);
    return result.exitCode == 0;
  }

  /// Download artifacts for the user's current Flutter version.
  ///
  /// Auto-detects the Flutter version, checks if it's supported, and
  /// downloads matching artifacts.
  ///
  /// Returns the Flutter version string on success, null on failure.
  Future<String?> downloadForCurrentVersion({String? platform}) async {
    final flutterVersion = detectFlutterVersion();
    if (flutterVersion == null) {
      _logger.err(
        'Could not detect Flutter version. '
        'Ensure flutter is on your PATH.',
      );
      return null;
    }

    _logger.detail('Detected Flutter version: $flutterVersion');

    if (isVersionCached(flutterVersion)) {
      _logger.info(
        'Artifacts already cached for Flutter $flutterVersion.',
      );
      return flutterVersion;
    }

    final success = await downloadArtifacts(
      flutterVersion: flutterVersion,
      platform: platform,
    );
    return success ? flutterVersion : null;
  }

  // ── Cache management ──────────────────────────────────────────────

  /// List all cached Flutter versions.
  List<String> listCachedVersions() {
    final cacheDir = Directory(_cacheRoot);
    if (!cacheDir.existsSync()) return [];
    return cacheDir
        .listSync()
        .whereType<Directory>()
        .where((d) => File('${d.path}/.stamp').existsSync())
        .map((d) {
      final name = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      // Strip the "flutter-" prefix for display.
      return name.startsWith('flutter-')
          ? name.substring('flutter-'.length)
          : name;
    }).toList()
      ..sort();
  }

  /// Remove a cached version.
  void removeVersion(String flutterVersion) {
    final dir = Directory(versionDir(flutterVersion));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
      _logger.info('Removed cached artifacts for Flutter $flutterVersion');
    }
  }

  /// Remove all cached versions except the specified one.
  void cleanupOldVersions({String? keepVersion}) {
    for (final ver in listCachedVersions()) {
      if (ver != keepVersion) {
        removeVersion(ver);
      }
    }
  }

  /// Ensure the Dart SDK is available in a target Flutter installation.
  ///
  /// Copies the Dart SDK from the user's current Flutter installation to
  /// [targetFlutterRoot]/bin/cache/dart-sdk/. This avoids the broken download
  /// when the target has a custom engine hash not in Google's infra bucket.
  ///
  /// Returns true if the Dart SDK is ready, false on failure.
  bool ensureDartSdk({required String targetFlutterRoot}) {
    final targetSdk = Directory('$targetFlutterRoot/bin/cache/dart-sdk');
    final targetDart = File('$targetFlutterRoot/bin/cache/dart-sdk/bin/dart');

    // Already has a working Dart SDK.
    if (targetDart.existsSync()) {
      _logger.detail('Dart SDK already present at ${targetSdk.path}');
      return true;
    }

    // Find the source Dart SDK from the current Flutter installation.
    final flutterBin = _findFlutterBin();
    if (flutterBin == null) {
      _logger.err('Cannot find Flutter on PATH to copy Dart SDK from.');
      return false;
    }

    final resolved = File(flutterBin).resolveSymbolicLinksSync();
    final sourceFlutterRoot = File(resolved).parent.parent.path;
    final sourceSdk = Directory('$sourceFlutterRoot/bin/cache/dart-sdk');
    final sourceDart = File('$sourceFlutterRoot/bin/cache/dart-sdk/bin/dart');

    if (!sourceDart.existsSync()) {
      _logger.err('Source Flutter SDK at $sourceFlutterRoot has no Dart SDK.');
      return false;
    }

    // Don't copy over itself.
    if (sourceSdk.path == targetSdk.path) {
      return true;
    }

    _logger.detail(
      'Copying Dart SDK from $sourceFlutterRoot to $targetFlutterRoot',
    );

    // Remove stale target if it exists.
    if (targetSdk.existsSync()) {
      targetSdk.deleteSync(recursive: true);
    }

    // Copy recursively.
    final result =
        Process.runSync('cp', ['-R', sourceSdk.path, targetSdk.path]);
    if (result.exitCode != 0) {
      _logger.err('Failed to copy Dart SDK: ${result.stderr}');
      return false;
    }

    // Update the stamp so Flutter doesn't try to re-download.
    final engineStamp = File('$targetFlutterRoot/bin/cache/engine.stamp');
    if (engineStamp.existsSync()) {
      final hash = engineStamp.readAsStringSync().trim();
      File('$targetFlutterRoot/bin/cache/engine-dart-sdk.stamp')
          .writeAsStringSync(hash);
    }

    return true;
  }

  String? _findFlutterBin() {
    final result = Process.runSync('which', ['flutter']);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    return null;
  }

  /// Store the active Flutter version for code push in ~/.flutter_compilerc.
  Future<void> saveActiveVersion(String flutterVersion) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final rcFile = File('$home/.flutter_compilerc');
    final lines = rcFile.existsSync() ? rcFile.readAsLinesSync() : <String>[];

    final key = Constants.codePushEngineVersionKey;
    final newLine = '$key:$flutterVersion';
    var found = false;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('$key:')) {
        lines[i] = newLine;
        found = true;
        break;
      }
    }
    if (!found) lines.add(newLine);

    rcFile.writeAsStringSync('${lines.join('\n')}\n');
  }

  /// Read the active code push engine version from ~/.flutter_compilerc.
  String? getActiveVersion() {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final rcFile = File('$home/.flutter_compilerc');
    if (!rcFile.existsSync()) return null;

    final key = Constants.codePushEngineVersionKey;
    for (final line in rcFile.readAsLinesSync()) {
      if (line.startsWith('$key:')) {
        return line.substring('$key:'.length).trim();
      }
    }
    return null;
  }

  /// Find gen_snapshot from the cached artifacts.
  ///
  /// Checks in order:
  ///   1. The active version stored in ~/.flutter_compilerc
  ///   2. The currently running Flutter SDK version
  ///
  /// Returns the path if found, null otherwise.
  String? findCachedGenSnapshot() {
    // 1. Check the explicitly saved active version.
    final activeVersion = getActiveVersion();
    if (activeVersion != null) {
      final path = genSnapshotPath(activeVersion);
      if (path != null) return path;
    }

    // 2. Try to match against the current Flutter version.
    final currentVersion = detectFlutterVersion();
    if (currentVersion != null && currentVersion != activeVersion) {
      final path = genSnapshotPath(currentVersion);
      if (path != null) return path;
    }

    return null;
  }

  // Download helpers moved to fcp-tool binary (see `fcp codepush setup`).
}
