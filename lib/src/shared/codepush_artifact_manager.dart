import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';

import 'constants.dart';

/// Manages downloading, caching, and verifying code-push-enabled build
/// artifacts **per Flutter SDK version**.
///
/// Everything that requires knowledge of the build pipeline layout is
/// delegated to the private `fcp-tool` binary (downloaded on demand).
/// This class keeps only high-level concerns: version detection, cache
/// listing, on-disk version bookkeeping, and bootstrap of `fcp-tool`.
class CodePushArtifactManager {
  CodePushArtifactManager({
    required Logger logger,
    String? baseUrl,
    String? cacheRoot,
    HttpClient Function()? httpClientFactory,
  })  : _logger = logger,
        _baseUrl = baseUrl ?? '',
        _cacheRoot = cacheRoot ??
            '${Platform.environment['HOME'] ?? '/tmp'}/.flutter_compile/cache/${Constants.codePushCacheDir}',
        _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final Logger _logger;
  final String _baseUrl;
  final String _cacheRoot;
  final HttpClient Function() _httpClientFactory;

  /// Public URL the CLI downloads the build tool from. The tool is stored
  /// in `gs://flutterplaza-codepush-artifacts/tools/<os>-<arch>/fcp-tool`.
  static const String _toolBucketBase =
      'https://storage.googleapis.com/flutterplaza-codepush-artifacts/tools';

  /// Returns the path to the build tool binary, downloading it first if
  /// needed. Returns null if the download fails.
  Future<String?> ensureBuildTool() async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final platform = currentPlatform;
    final cacheDir = Directory('$home/.flutter_compile/cache/tools');
    final cached = File('${cacheDir.path}/fcp-tool-$platform');

    if (cached.existsSync()) return cached.path;

    cacheDir.createSync(recursive: true);
    final url = '$_toolBucketBase/$platform/fcp-tool';
    final progress = _logger.progress('Downloading build tool');
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        progress
            .fail('Build tool download failed (HTTP ${response.statusCode})');
        return null;
      }
      final sink = cached.openWrite();
      await response.pipe(sink);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', cached.path]);
      }
      progress.complete('Build tool ready');
      return cached.path;
    } on Exception catch (e) {
      progress.fail('Build tool download error: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

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

  // ── Flutter version detection ─────────────────────────────────────

  /// Detect the Flutter SDK version the user currently has active.
  String? detectFlutterVersion() {
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

    try {
      final whichResult = Process.runSync('which', ['flutter']);
      if (whichResult.exitCode == 0) {
        final flutterBin = (whichResult.stdout as String).trim();
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

  /// Check if artifacts for a Flutter version are already cached and verified.
  bool isVersionCached(String flutterVersion) {
    final stampFile = File('${versionDir(flutterVersion)}/.stamp');
    return stampFile.existsSync();
  }

  // ── Version manifest ──────────────────────────────────────────────

  /// Fetch the versions manifest from the server.
  Future<Map<String, String>?> fetchSupportedVersions() async {
    final url = '$_baseUrl/versions.json';
    _logger.detail('Fetching supported versions from: $url');
    try {
      final client = _httpClientFactory();
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
  Future<bool> downloadArtifacts({
    required String flutterVersion,
    String? platform,
  }) async {
    final targetPlatform = platform ?? currentPlatform;
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
  /// [targetFlutterRoot]/bin/cache/dart-sdk/. This avoids the broken
  /// download when the target has a custom hash not in Google's bucket.
  bool ensureDartSdk({required String targetFlutterRoot}) {
    final targetSdk = Directory('$targetFlutterRoot/bin/cache/dart-sdk');
    final targetDart = File('$targetFlutterRoot/bin/cache/dart-sdk/bin/dart');

    if (targetDart.existsSync()) {
      _logger.detail('Dart SDK already present at ${targetSdk.path}');
      return true;
    }

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

    if (sourceSdk.path == targetSdk.path) {
      return true;
    }

    _logger.detail(
      'Copying Dart SDK from $sourceFlutterRoot to $targetFlutterRoot',
    );

    if (targetSdk.existsSync()) {
      targetSdk.deleteSync(recursive: true);
    }

    final result =
        Process.runSync('cp', ['-R', sourceSdk.path, targetSdk.path]);
    if (result.exitCode != 0) {
      _logger.err('Failed to copy Dart SDK: ${result.stderr}');
      return false;
    }

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
}
