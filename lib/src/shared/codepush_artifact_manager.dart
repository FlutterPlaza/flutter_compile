import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

import 'constants.dart';

/// Manages downloading, caching, and verifying code-push-enabled engine
/// artifacts (gen_snapshot, libflutter) **per Flutter SDK version**.
///
/// Artifacts are stored at:
///   `~/.flutter_compile/cache/codepush-engine/<flutter-version>/<platform>/`
///
/// Example:
///   `~/.flutter_compile/cache/codepush-engine/3.24.0/darwin-arm64/gen_snapshot`
///
/// Each platform directory contains:
///   - gen_snapshot (AOT compiler with stable object pool indices)
///   - libflutter.so / libflutter_engine.dylib (engine with code push C++)
///
/// Artifacts are verified via SHA-256 checksums downloaded alongside them.
///
/// The server publishes a `versions.json` manifest listing all supported
/// Flutter SDK versions and their build revisions.
class CodePushArtifactManager {
  CodePushArtifactManager({
    required Logger logger,
    String? baseUrl,
    String? cacheRoot,
  })  : _logger = logger,
        _baseUrl = baseUrl ?? Constants.codePushArtifactBaseUrl,
        _cacheRoot = cacheRoot ??
            '${Platform.environment['HOME'] ?? '/tmp'}/.flutter_compile/cache/${Constants.codePushCacheDir}';

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

  /// All platforms we distribute artifacts for.
  static const platforms = [
    'darwin-arm64',
    'darwin-x64',
    'linux-x64',
    'windows-x64',
  ];

  /// Artifacts distributed per platform.
  static const _artifactNames = {
    'darwin-arm64': ['gen_snapshot', 'libflutter_engine.dylib'],
    'darwin-x64': ['gen_snapshot', 'libflutter_engine.dylib'],
    'linux-x64': ['gen_snapshot', 'libflutter.so'],
    'windows-x64': ['gen_snapshot.exe', 'flutter_engine.dll'],
  };

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
    final path =
        '${versionDir(flutterVersion)}/$currentPlatform/gen_snapshot${Platform.isWindows ? '.exe' : ''}';
    return File(path).existsSync() ? path : null;
  }

  /// Path to the engine library for the current platform and a given version.
  String? engineLibraryPath(String flutterVersion) {
    final names = _artifactNames[currentPlatform];
    if (names == null || names.length < 2) return null;
    final path =
        '${versionDir(flutterVersion)}/$currentPlatform/${names[1]}';
    return File(path).existsSync() ? path : null;
  }

  /// Check if artifacts for a Flutter version are already cached and verified.
  bool isVersionCached(String flutterVersion) {
    final stampFile = File('${versionDir(flutterVersion)}/.stamp');
    return stampFile.existsSync();
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
    final artifacts = _artifactNames[targetPlatform];
    if (artifacts == null) {
      _logger.err('Unknown platform: $targetPlatform');
      return false;
    }

    final dir =
        Directory('${versionDir(flutterVersion)}/$targetPlatform');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    // The GCS path is: <baseUrl>/flutter-<version>/<platform>/<artifact>
    final versionPrefix = 'flutter-$flutterVersion';

    // Download checksums first.
    final checksums =
        await _downloadChecksums(versionPrefix, targetPlatform);

    // Download each artifact.
    for (final artifact in artifacts) {
      final url = '$_baseUrl/$versionPrefix/$targetPlatform/$artifact';
      final destPath = '${dir.path}/$artifact';

      _logger.info(
        'Downloading $artifact for Flutter $flutterVersion ($targetPlatform)...',
      );
      final success = await _downloadFile(url, destPath);
      if (!success) {
        _logger.err('Failed to download $artifact');
        return false;
      }

      // Verify checksum.
      if (checksums.containsKey(artifact)) {
        final expectedHash = checksums[artifact]!;
        final actualHash = await _computeSha256(destPath);
        if (actualHash != expectedHash) {
          _logger.err(
            'SHA-256 mismatch for $artifact:\n'
            '  Expected: $expectedHash\n'
            '  Actual:   $actualHash',
          );
          File(destPath).deleteSync();
          return false;
        }
        _logger.detail('  SHA-256 verified: $artifact');
      }

      // Make executables executable on Unix.
      if (!Platform.isWindows && artifact.contains('gen_snapshot')) {
        await Process.run('chmod', ['+x', destPath]);
      }
    }

    // Write stamp file to mark this version as complete.
    File('${versionDir(flutterVersion)}/.stamp').writeAsStringSync(
      '${DateTime.now().toUtc().toIso8601String()}\n'
      'flutter_version=$flutterVersion\n'
      'platform=$targetPlatform\n',
    );

    return true;
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
          final name =
              d.uri.pathSegments.where((s) => s.isNotEmpty).last;
          // Strip the "flutter-" prefix for display.
          return name.startsWith('flutter-')
              ? name.substring('flutter-'.length)
              : name;
        })
        .toList()
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

  /// Store the active Flutter version for code push in ~/.flutter_compilerc.
  Future<void> saveActiveVersion(String flutterVersion) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final rcFile = File('$home/.flutter_compilerc');
    final lines =
        rcFile.existsSync() ? rcFile.readAsLinesSync() : <String>[];

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

  // ── Private helpers ──────────────────────────────────────────────

  Future<Map<String, String>> _downloadChecksums(
    String versionPrefix,
    String platform,
  ) async {
    final url = '$_baseUrl/$versionPrefix/$platform/checksums.sha256';
    final checksums = <String, String>{};
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode != 200) return checksums;
        final body = await response.transform(utf8.decoder).join();
        for (final line in body.split('\n')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length == 2) {
            checksums[parts[1]] = parts[0];
          }
        }
      } finally {
        client.close();
      }
    } on Exception {
      // Checksums are optional; proceed without them.
    }
    return checksums;
  }

  Future<bool> _downloadFile(String url, String destPath) async {
    try {
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode != 200) {
          _logger.detail('HTTP ${response.statusCode} for $url');
          return false;
        }

        final file = File(destPath);
        final sink = file.openWrite();
        final totalBytes = response.contentLength;
        var receivedBytes = 0;

        await for (final chunk in response) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          if (totalBytes > 0) {
            final pct =
                (receivedBytes / totalBytes * 100).toStringAsFixed(0);
            stdout.write('\r  $pct% ($receivedBytes / $totalBytes bytes)');
          }
        }
        stdout.write('\n');
        await sink.close();
        return true;
      } finally {
        client.close();
      }
    } on Exception catch (e) {
      _logger.err('Download failed: $e');
      return false;
    }
  }

  Future<String> _computeSha256(String filePath) async {
    final bytes = await File(filePath).readAsBytes();
    return sha256.convert(bytes).toString();
  }
}
