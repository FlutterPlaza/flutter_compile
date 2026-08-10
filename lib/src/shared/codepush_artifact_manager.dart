import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:mason_logger/mason_logger.dart';

import 'constants.dart';

/// Manages downloading, caching, and verifying code-push build
/// artifacts per Flutter SDK version.
///
/// High-level concerns: version detection, cache listing, on-disk
/// version bookkeeping, and build tool bootstrap.
class CodePushArtifactManager {
  CodePushArtifactManager({
    required Logger logger,
    String? baseUrl,
    String? cacheRoot,
    HttpClient Function()? httpClientFactory,
  })  : _logger = logger,
        _baseUrl = baseUrl ?? _defaultArtifactBucketBase,
        _cacheRoot = cacheRoot ??
            '${Platform.environment['HOME'] ?? '/tmp'}/.flutter_compile/cache/${Constants.codePushCacheDir}',
        _httpClientFactory = httpClientFactory ?? HttpClient.new;

  /// Artifact server base URL for engine binaries.
  static const String _defaultArtifactBucketBase =
      'https://storage.googleapis.com/flutterplaza-codepush-artifacts';

  final Logger _logger;
  final String _baseUrl;
  final String _cacheRoot;
  final HttpClient Function() _httpClientFactory;

  /// Artifact server URL for the private build tool binary.
  static const String _toolBucketBase =
      'https://storage.googleapis.com/flutterplaza-codepush-artifacts/tools';

  /// Returns the path to the build tool binary, downloading it first if
  /// needed. Returns null if the download fails.
  ///
  /// The cache is version-keyed against the published `tools/versions.json`
  /// manifest: when the manifest is reachable and its sha256 for this
  /// platform differs from the cached binary, the tool is re-downloaded.
  /// This keeps a stale cached tool from silently missing newer
  /// subcommands. When the manifest can't be fetched (offline), an
  /// existing cached tool is used as-is.
  Future<String?> ensureBuildTool({bool forceRefresh = false}) async {
    final home = Platform.environment['HOME'] ?? '/tmp';
    final platform = currentPlatform;
    final cacheDir = Directory('$home/.flutter_compile/cache/tools');
    final cached = File('${cacheDir.path}/fcp-tool-$platform');
    final stamp = File('${cacheDir.path}/fcp-tool-$platform.checked');

    // Version-check at most once per window: a freshly-verified cached
    // tool returns instantly (no network) so the common path — and the
    // offline path — isn't gated on a manifest fetch. The window bounds
    // how long a tool update can go unnoticed. [forceRefresh] bypasses
    // the window so `setup --force` re-consults the manifest and
    // re-downloads on any sha change, even right after the tool ran.
    if (!forceRefresh && cached.existsSync() && _checkedRecently(stamp)) {
      return cached.path;
    }

    final expectedSha = await _fetchExpectedToolSha(platform);

    if (cached.existsSync()) {
      // No manifest (offline) → trust the cache. Manifest present and
      // matching → cache is current. Only a definite mismatch re-downloads.
      // Stamp on both trust paths, so a repeated offline call within the
      // window returns instantly instead of re-eating the manifest
      // timeout each time.
      if (expectedSha == null) {
        _touch(stamp);
        return cached.path;
      }
      final currentSha = sha256.convert(cached.readAsBytesSync()).toString();
      if (currentSha == expectedSha) {
        _touch(stamp);
        return cached.path;
      }
      _logger.detail('Build tool is out of date — refreshing.');
    }

    cacheDir.createSync(recursive: true);
    final url = '$_toolBucketBase/$platform/fcp-tool';
    final progress = _logger.progress('Downloading build tool');
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        progress.fail(
          'Build tool download failed (HTTP ${response.statusCode})',
        );
        return null;
      }
      // Download to a temp file and rename on success, so an interrupted
      // download never leaves a truncated tool in the cache.
      final tmp = File('${cached.path}.download');
      final sink = tmp.openWrite();
      await response.pipe(sink);
      if (expectedSha != null) {
        final gotSha = sha256.convert(tmp.readAsBytesSync()).toString();
        if (gotSha != expectedSha) {
          tmp.deleteSync();
          progress.fail('Build tool checksum mismatch — download rejected.');
          return null;
        }
      }
      tmp.renameSync(cached.path);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['+x', cached.path]);
      }
      _touch(stamp);
      progress.complete('Build tool ready');
      return cached.path;
    } on Exception catch (e) {
      progress.fail('Build tool download error: $e');
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// How long a verified cached tool is trusted before re-checking the
  /// manifest.
  static const Duration _toolCheckWindow = Duration(hours: 6);

  bool _checkedRecently(File stamp) {
    try {
      if (!stamp.existsSync()) return false;
      return DateTime.now().difference(stamp.lastModifiedSync()) <
          _toolCheckWindow;
    } on Exception {
      return false;
    }
  }

  void _touch(File stamp) {
    try {
      stamp.writeAsStringSync('${DateTime.now().toIso8601String()}\n');
    } on Exception {
      // A missing stamp only costs an extra manifest fetch next time.
    }
  }

  /// Best-effort fetch of the expected sha256 for [platform] from the
  /// tools manifest. Returns null when the manifest is unreachable, is
  /// malformed, or has no entry, so callers fall back to the cached tool.
  Future<String?> _fetchExpectedToolSha(String platform) async {
    final client = _httpClientFactory();
    try {
      final request = await client
          .getUrl(Uri.parse('$_toolBucketBase/versions.json'))
          .timeout(const Duration(seconds: 5));
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;
      // Bound the body read too: a connection that stalls mid-body must
      // not hang the version check and defeat the freshness window.
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5));
      // `is` checks (not `as` casts): a 200 body that isn't the expected
      // shape — a JSON array, a captive-portal page, sha256 as a number —
      // must degrade to "unknown" (→ trust the cache), not throw a
      // TypeError (an Error, not an Exception) that escapes this
      // best-effort path.
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final entry = decoded[platform];
      if (entry is! Map<String, dynamic>) return null;
      final sha = entry['sha256'];
      return sha is String ? sha : null;
    } on Exception {
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

  /// The `android-arm64` engine cache directory for [flutterVersion] —
  /// where `finalize`'s engine swap reads `libflutter.so` and where the
  /// Android AOT `gen_snapshot` lives.
  String androidEngineDir(String flutterVersion) =>
      '${versionDir(flutterVersion)}/android-arm64';

  /// Whether the Android engine set for [flutterVersion] is already in the
  /// cache (both files the Android build needs).
  bool isAndroidEngineCached(String flutterVersion) {
    final dir = androidEngineDir(flutterVersion);
    return File('$dir/libflutter.so').existsSync() &&
        File('$dir/gen_snapshot').existsSync();
  }

  /// Ensures the `android-arm64` engine set (`libflutter.so` +
  /// `gen_snapshot`) is cached for [flutterVersion], downloading it if
  /// missing. Unlike iOS, Android needs no Flutter-SDK-cache install:
  /// `fcp-tool finalize` swaps `libflutter.so` straight from this cache
  /// into the built APK, and the patch compile reads `gen_snapshot`
  /// from here — so a verified download is the whole install.
  Future<bool> ensureAndroidEngine({
    required String flutterVersion,
    bool force = false,
  }) async {
    if (!force && isAndroidEngineCached(flutterVersion)) return true;
    return downloadArtifacts(
      flutterVersion: flutterVersion,
      platform: 'android-arm64',
    );
  }

  /// Finalize the code-push engine install into the active Flutter SDK.
  /// On macOS hosts, installs the iOS target overlay so
  /// `flutter build ios --release` produces a code-push-capable app.
  /// Downloads the iOS target files on demand if the host-platform
  /// [downloadArtifacts] step didn't already cache them.
  Future<bool> installOverlaysIntoFlutterSdk({
    required String flutterVersion,
    required String platform,
  }) async {
    if (!Platform.isMacOS) {
      _logger.detail(
        'installOverlaysIntoFlutterSdk: iOS target install only runs on macOS',
      );
      return true;
    }

    const iosTarget = 'ios-arm64';
    final overrideDirPath =
        Platform.environment['FCP_CODEPUSH_IOS_ENGINE_DIR']?.trim();
    final usingLocalOverride =
        overrideDirPath != null && overrideDirPath.isNotEmpty;
    final iosDir = Directory(platformDir(flutterVersion, iosTarget));
    iosDir.createSync(recursive: true);

    File platformStrong;
    File vmOutline;
    File genSnapshotSrc;
    Directory? frameworkOverrideDir;
    File? xcframeworkTar;

    if (usingLocalOverride) {
      final overrideDir = Directory(overrideDirPath);
      if (!overrideDir.existsSync()) {
        _logger.err(
          'FCP_CODEPUSH_IOS_ENGINE_DIR does not exist: $overrideDirPath',
        );
        return false;
      }

      // Look for patched SDK dills in both flutter_patched_sdk/ (raw build
      // output) and flutter_patched_sdk_product/ (some build configs).
      platformStrong = File(
        '${overrideDir.path}/flutter_patched_sdk/platform_strong.dill',
      );
      if (!platformStrong.existsSync()) {
        platformStrong = File(
          '${overrideDir.path}/flutter_patched_sdk_product/platform_strong.dill',
        );
      }
      vmOutline = File(
        '${overrideDir.path}/flutter_patched_sdk/vm_outline_strong.dill',
      );
      if (!vmOutline.existsSync()) {
        vmOutline = File(
          '${overrideDir.path}/flutter_patched_sdk_product/vm_outline_strong.dill',
        );
      }
      // Look for gen_snapshot in multiple locations to support both
      // the expected layout (gen_snapshot_arm64 at root) and the raw
      // engine build output (clang_arm64/gen_snapshot or clang_x64/gen_snapshot).
      genSnapshotSrc = File('${overrideDir.path}/gen_snapshot_arm64');
      if (!genSnapshotSrc.existsSync()) {
        genSnapshotSrc = File('${overrideDir.path}/clang_arm64/gen_snapshot');
      }
      if (!genSnapshotSrc.existsSync()) {
        genSnapshotSrc = File('${overrideDir.path}/clang_x64/gen_snapshot');
      }
      if (!genSnapshotSrc.existsSync()) {
        genSnapshotSrc = File('${overrideDir.path}/gen_snapshot');
      }

      final xcfwFramework = Directory(
        '${overrideDir.path}/Flutter.xcframework/ios-arm64/Flutter.framework',
      );
      final flatFramework = Directory('${overrideDir.path}/Flutter.framework');
      if (xcfwFramework.existsSync()) {
        frameworkOverrideDir = xcfwFramework;
      } else if (flatFramework.existsSync()) {
        frameworkOverrideDir = flatFramework;
      }

      for (final file in <File>[platformStrong, vmOutline, genSnapshotSrc]) {
        if (!file.existsSync()) {
          _logger.err(
            'Missing local iOS engine override artifact: ${file.path}',
          );
          return false;
        }
      }
      if (frameworkOverrideDir == null) {
        _logger.err(
          'Missing local iOS engine override framework under $overrideDirPath',
        );
        return false;
      }
      _logger.detail('Using local iOS engine override from $overrideDirPath');
    } else {
      // Always re-download iOS target files from GCS. A previous
      // `--force` run may have cached an older version and the
      // exists-check would skip the update.
      for (final name in const <String>[
        'platform_strong.dill',
        'vm_outline_strong.dill',
        'Flutter.xcframework.tar.gz',
        'gen_snapshot',
      ]) {
        final f = File('${iosDir.path}/$name');
        final url = '$_baseUrl/flutter-$flutterVersion/$iosTarget/$name';
        _logger.detail('Fetching $name from $url');
        final ok = await _fetchToFile(url, f);
        if (!ok) {
          _logger.err('Could not download $name from $url');
          return false;
        }
      }

      platformStrong = File('${iosDir.path}/platform_strong.dill');
      vmOutline = File('${iosDir.path}/vm_outline_strong.dill');
      genSnapshotSrc = File('${iosDir.path}/gen_snapshot');
      xcframeworkTar = File('${iosDir.path}/Flutter.xcframework.tar.gz');
    }

    final flutterRoot = _findActiveFlutterRoot();
    if (flutterRoot == null) {
      _logger.err(
        'Could not locate the active Flutter install — is `flutter` on your PATH?',
      );
      return false;
    }

    final engineCache = '$flutterRoot/bin/cache/artifacts/engine';
    final productSdkDir = Directory(
      '$engineCache/common/flutter_patched_sdk_product',
    );
    final iosReleaseDir = Directory('$engineCache/ios-release');
    final frameworkDir = Directory(
      '$engineCache/ios-release/Flutter.xcframework/ios-arm64/Flutter.framework',
    );

    if (!productSdkDir.existsSync() ||
        !iosReleaseDir.existsSync() ||
        !frameworkDir.existsSync()) {
      _logger.err(
        'Flutter SDK cache at $engineCache is missing expected subdirectories. '
        'Run `flutter precache --ios` first, then re-run `fcp codepush setup`.',
      );
      return false;
    }

    if (!platformStrong.existsSync() ||
        !vmOutline.existsSync() ||
        !genSnapshotSrc.existsSync()) {
      _logger.err('Missing one or more iOS overlay files.');
      return false;
    }
    if (!usingLocalOverride &&
        (xcframeworkTar == null || !xcframeworkTar.existsSync())) {
      _logger.err('Missing overlay file: ${xcframeworkTar?.path ?? 'unknown'}');
      return false;
    }

    // Backup stock files before overwriting.
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp('[^0-9]'), '')
        .substring(0, 14);
    final backupDir = Directory('$engineCache/.fcp-stock-backup-$stamp');
    backupDir.createSync(recursive: true);
    Directory(
      '${backupDir.path}/flutter_patched_sdk_product',
    ).createSync(recursive: true);
    Directory(
      '${backupDir.path}/ios-release/Flutter.framework',
    ).createSync(recursive: true);

    void backup(File src, String destRel) {
      if (!src.existsSync()) return;
      final dest = File('${backupDir.path}/$destRel');
      dest.parent.createSync(recursive: true);
      dest.writeAsBytesSync(src.readAsBytesSync());
    }

    final stockPlatform = File('${productSdkDir.path}/platform_strong.dill');
    final stockVmOutline = File('${productSdkDir.path}/vm_outline_strong.dill');
    final stockFlutter = File('${frameworkDir.path}/Flutter');
    final stockGenSnap = File('${iosReleaseDir.path}/gen_snapshot_arm64');

    backup(stockPlatform, 'flutter_patched_sdk_product/platform_strong.dill');
    backup(
      stockVmOutline,
      'flutter_patched_sdk_product/vm_outline_strong.dill',
    );
    backup(stockFlutter, 'ios-release/Flutter.framework/Flutter');
    backup(stockGenSnap, 'ios-release/gen_snapshot_arm64');
    _logger.detail('Stock artifacts backed up to ${backupDir.path}');

    stockPlatform.writeAsBytesSync(platformStrong.readAsBytesSync());
    stockVmOutline.writeAsBytesSync(vmOutline.readAsBytesSync());
    stockGenSnap.writeAsBytesSync(genSnapshotSrc.readAsBytesSync());

    if (usingLocalOverride) {
      final frameworkBinary = File('${frameworkOverrideDir!.path}/Flutter');
      if (!frameworkBinary.existsSync()) {
        _logger.err(
          'Local iOS engine override is missing Flutter.framework/Flutter',
        );
        return false;
      }
      stockFlutter.writeAsBytesSync(frameworkBinary.readAsBytesSync());
    } else {
      // Extract xcframework to a temp dir and locate the ios-arm64 binary.
      final tempXcf = Directory.systemTemp.createTempSync('fcp-xcf-');
      try {
        final tarResult = Process.runSync('tar', [
          '-xzf',
          xcframeworkTar!.path,
          '-C',
          tempXcf.path,
        ]);
        if (tarResult.exitCode != 0) {
          _logger.err(
            'Failed to extract Flutter.xcframework.tar.gz: ${tarResult.stderr}',
          );
          return false;
        }
        final newFlutter = File(
          '${tempXcf.path}/Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
        );
        if (!newFlutter.existsSync()) {
          _logger.err('Extracted xcframework missing Flutter binary.');
          return false;
        }
        stockFlutter.writeAsBytesSync(newFlutter.readAsBytesSync());
      } finally {
        try {
          tempXcf.deleteSync(recursive: true);
        } on Exception {
          /* best-effort */
        }
      }
    }

    if (!Platform.isWindows) {
      Process.runSync('chmod', ['+x', stockGenSnap.path]);
      Process.runSync('chmod', ['+x', stockFlutter.path]);
    }

    _logger.detail('Overlays installed into $engineCache');
    return true;
  }

  /// Absolute path of the cached platform directory for a Flutter version.
  String platformDir(String flutterVersion, String platform) =>
      '${versionDir(flutterVersion)}/$platform';

  /// Resolve the root directory of the currently active Flutter install.
  /// Follows the symlink chain that `fcp switch` uses.
  String? _findActiveFlutterRoot() {
    final bin = _findFlutterBin();
    if (bin == null) return null;
    try {
      final resolved = File(bin).resolveSymbolicLinksSync();
      return File(resolved).parent.parent.path;
    } on FileSystemException {
      return null;
    }
  }

  /// Download [url] to [dest] via plain HTTP GET. Returns true on success.
  Future<bool> _fetchToFile(String url, File dest) async {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (response.statusCode != 200) {
        _logger.err('HTTP ${response.statusCode} for $url');
        return false;
      }
      dest.parent.createSync(recursive: true);
      await response.pipe(dest.openWrite());
      return true;
    } on Exception catch (e) {
      _logger.err('Download error: $e');
      return false;
    } finally {
      client.close(force: true);
    }
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
      _logger.info('Artifacts already cached for Flutter $flutterVersion.');
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

    final result = Process.runSync('cp', [
      '-R',
      sourceSdk.path,
      targetSdk.path,
    ]);
    if (result.exitCode != 0) {
      _logger.err('Failed to copy Dart SDK: ${result.stderr}');
      return false;
    }

    final engineStamp = File('$targetFlutterRoot/bin/cache/engine.stamp');
    if (engineStamp.existsSync()) {
      final hash = engineStamp.readAsStringSync().trim();
      File(
        '$targetFlutterRoot/bin/cache/engine-dart-sdk.stamp',
      ).writeAsStringSync(hash);
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
