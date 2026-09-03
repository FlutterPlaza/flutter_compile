import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushSetupSubCommand extends Command<int> {
  CodePushSetupSubCommand(this._logger) {
    argParser
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK version to download artifacts for '
            '(e.g., 3.24.0). Auto-detected if omitted.',
      )
      ..addOption(
        'platform',
        help: 'Target platform to set up (e.g. apk/android, ios, '
            'darwin-arm64, linux-x64). Defaults to the host platform '
            "plus any target the project directory shows it builds.",
      )
      ..addFlag(
        'force',
        help: 'Re-download even if already cached.',
        defaultsTo: false,
      )
      ..addFlag(
        'cleanup',
        help: 'Remove cached artifacts for other Flutter versions.',
        defaultsTo: false,
      )
      ..addFlag(
        'list-versions',
        help: 'List all Flutter versions with available code push artifacts.',
        defaultsTo: false,
      );
  }

  final Logger _logger;

  @override
  final String name = 'setup';
  @override
  final String description =
      'Download code-push-enabled engine artifacts matching your Flutter SDK version.';

  @override
  Future<int> run() async {
    final manager = CodePushArtifactManager(logger: _logger);
    final force = argResults?['force'] as bool? ?? false;
    final cleanup = argResults?['cleanup'] as bool? ?? false;
    final listVersions = argResults?['list-versions'] as bool? ?? false;
    final targetPlatform = argResults?['platform'] as String?;

    // --list-versions: show supported versions and exit.
    if (listVersions) {
      return _listVersions(manager);
    }

    // Ensure the build tool is ready (bootstrap download if missing).
    // `--force` re-consults the manifest and re-downloads on any change,
    // so it's the real recovery path for a stale/broken cached tool.
    final tool = await manager.ensureBuildTool(forceRefresh: force);
    if (tool == null) {
      return ExitCode.software.code;
    }

    // Determine the Flutter version to download for.
    var flutterVersion = argResults?['flutter-version'] as String?;
    if (flutterVersion == null) {
      final progress = _logger.progress('Detecting Flutter SDK version');
      flutterVersion = manager.detectFlutterVersion();
      if (flutterVersion == null) {
        progress.fail(
          'Could not detect Flutter version. '
          'Use --flutter-version to specify it manually.',
        );
        return ExitCode.software.code;
      }
      progress.complete('Flutter $flutterVersion');
    }

    // Explicit Android target: fetch just the android-arm64 engine into
    // the cache and stop. Android needs no Flutter-SDK-cache overlay —
    // `finalize` swaps libflutter.so straight from the cache — and the
    // host/iOS steps below would only fetch files Android doesn't use
    // (and fail if the iOS set for this version isn't published), so the
    // Android path is handled on its own here.
    if (_isAndroidPlatform(targetPlatform)) {
      // Platform-aware when the server publishes per-platform support:
      // a version can be live for iOS while its Android artifacts are
      // not yet published (or vice versa).
      final supported = await manager.isVersionSupportedForPlatform(
        flutterVersion,
        'android-arm64',
      );
      if (!supported) {
        _logger.err(
          'Flutter $flutterVersion does not support Android code push '
          'yet. Run `fcp codepush versions` to see per-platform support.',
        );
        return ExitCode.software.code;
      }
      final androidProgress = _logger.progress(
        'Downloading Android engine (android-arm64)',
      );
      final ok = await manager.ensureAndroidEngine(
        flutterVersion: flutterVersion,
        force: force,
      );
      if (!ok) {
        androidProgress.fail('Failed to download the Android engine.');
        return ExitCode.software.code;
      }
      androidProgress.complete('Android engine ready');
      await manager.saveActiveVersion(flutterVersion);
      _logger.success(
        'Code push is ready for Android (Flutter $flutterVersion).',
      );
      return ExitCode.success.code;
    }

    // Check if already cached.
    if (!force && manager.isVersionCached(flutterVersion)) {
      _logger.info(
        'Build artifacts already cached for Flutter $flutterVersion.',
      );
      _logger.info(
        '  Path: ${manager.versionDir(flutterVersion)}/${targetPlatform ?? manager.currentPlatform}',
      );
      await manager.saveActiveVersion(flutterVersion);

      // Always install overlays into the active Flutter SDK cache, even
      // when artifacts are already cached.  Without this, the custom
      // gen_snapshot and Flutter.framework are never copied into the SDK
      // cache — the app builds with stock artifacts and crashes at
      // launch with "Wrong full snapshot version."
      final resolvedPlatform = targetPlatform ?? manager.currentPlatform;
      final installProgress = _logger.progress(
        'Installing overlays into active Flutter SDK cache',
      );
      final installed = await manager.installOverlaysIntoFlutterSdk(
        flutterVersion: flutterVersion,
        platform: resolvedPlatform,
      );
      if (!installed) {
        installProgress.fail('Failed to install overlays.');
        return ExitCode.software.code;
      }
      installProgress.complete('Overlays installed.');

      await _autoFetchAndroidIfTargeted(manager, flutterVersion, force: force);

      _logger.success('Code push is ready.');
      return ExitCode.success.code;
    }

    // Check if this version is supported before attempting download.
    // Only iOS-overlay runs gate on iOS support specifically — a
    // version listed only for Android would previously pass a generic
    // check and then die on raw HTTP errors downloading overlay files
    // that don't exist. Host-only runs (Linux/Windows, explicit host
    // targets) keep the version-level check: their overlay step is a
    // no-op.
    final checkProgress = _logger.progress(
      'Checking server for Flutter $flutterVersion artifacts',
    );
    final needsIos = setupNeedsIosSupport(
      targetPlatform: targetPlatform,
      isMacOsHost: Platform.isMacOS,
    );
    final supported = needsIos
        ? await manager.isVersionSupportedForPlatform(
            flutterVersion,
            'ios-arm64',
          )
        : await manager.isVersionSupported(flutterVersion);
    if (!supported) {
      checkProgress.fail(
        needsIos
            ? 'Flutter $flutterVersion does not support iOS code push yet.'
            : 'Flutter $flutterVersion is not yet supported for code push.',
      );
      _logger.info('');
      _logger.info('Run `fcp codepush versions` to see per-platform '
          'support, or pass `--platform android` for an Android-only '
          'setup.');
      return ExitCode.software.code;
    }
    checkProgress.complete('Flutter $flutterVersion is supported');

    // Download artifacts.
    final progress = _logger.progress(
      'Downloading build artifacts for '
      '${targetPlatform ?? manager.currentPlatform}',
    );

    final success = await manager.downloadArtifacts(
      flutterVersion: flutterVersion,
      platform: targetPlatform,
    );

    if (!success) {
      progress.fail('Failed to download build artifacts');
      return ExitCode.software.code;
    }

    progress.complete('Build artifacts downloaded');

    // Install the downloaded overlays into the active Flutter SDK cache so
    // that `flutter build ios --release` produces a code-push-capable
    // `Runner.app`. Without this, download-only cached files in
    // `~/.flutter_compile/cache/codepush-engine/` are invisible to the
    // stock Flutter build pipeline.
    final resolvedPlatform = targetPlatform ?? manager.currentPlatform;
    final installProgress = _logger.progress(
      'Installing overlays into active Flutter SDK cache',
    );
    final installed = await manager.installOverlaysIntoFlutterSdk(
      flutterVersion: flutterVersion,
      platform: resolvedPlatform,
    );
    if (!installed) {
      installProgress.fail(
        'Failed to install overlays into Flutter SDK cache',
      );
      return ExitCode.software.code;
    }
    installProgress.complete('Overlays installed into Flutter SDK cache');

    // Save as active version.
    await manager.saveActiveVersion(flutterVersion);

    _logger.info('  Cached at: ${manager.versionDir(flutterVersion)}');

    // Ensure Dart SDK is available in the contribution Flutter repo.
    // This prevents the broken download when the repo has a custom
    // engine hash not in Google's infrastructure bucket.
    // Via F.homeDir() like every other home-relative path: on Windows
    // `HOME` is normally unset, so the old expression looked for the
    // contribution repo under C:\tmp and never found it.
    final home = F.homeDir();
    final contributionRepo = Directory('$home/flutter_compile/flutter');
    if (contributionRepo.existsSync()) {
      final sdkProgress = _logger.progress('Ensuring Dart SDK is available');
      final sdkOk = manager.ensureDartSdk(
        targetFlutterRoot: contributionRepo.path,
      );
      if (sdkOk) {
        sdkProgress.complete('Dart SDK ready');
      } else {
        sdkProgress.fail(
          'Could not copy Dart SDK. '
          '`fcp switch` may fail to download it.',
        );
      }
    }

    await _autoFetchAndroidIfTargeted(manager, flutterVersion, force: force);

    // Clean up other versions if requested.
    if (cleanup) {
      manager.cleanupOldVersions(keepVersion: flutterVersion);
    }

    _logger.success(
      'Code push is ready for Flutter $flutterVersion.',
    );
    return ExitCode.success.code;
  }

  /// Whether [platform] names the Android target in any of its accepted
  /// spellings (all map to the `android-arm64` engine set).
  static bool _isAndroidPlatform(String? platform) => const {
        'apk',
        'appbundle',
        'android',
        'android-arm64',
      }.contains(platform);

  /// Whether this setup run installs the iOS overlay set — and must
  /// therefore gate on iOS support specifically.
  ///
  /// The overlay installer runs unconditionally on macOS hosts (the
  /// platform argument is not consulted for that decision), so on a Mac
  /// every non-Android run needs iOS support — including explicit host
  /// targets like `darwin-arm64`. Off macOS the overlay step is a no-op
  /// and only an explicit iOS spelling gates on iOS (semantically the
  /// run is about iOS even though nothing downloads).
  static bool setupNeedsIosSupport({
    required String? targetPlatform,
    required bool isMacOsHost,
  }) {
    if (isMacOsHost) return true;
    return const {'ios', 'ipa', 'ios-arm64'}.contains(targetPlatform);
  }

  /// When no explicit `--platform` was given and the project directory
  /// shows it builds for Android, make sure the Android engine is cached
  /// too — a Flutter app commonly targets both iOS and Android, and the
  /// host/iOS-oriented setup above never fetches it. Best-effort: a
  /// failure here warns but doesn't fail the whole setup.
  Future<void> _autoFetchAndroidIfTargeted(
    CodePushArtifactManager manager,
    String flutterVersion, {
    required bool force,
  }) async {
    if (_isAndroidPlatform(argResults?['platform'] as String?)) return;
    if (!Directory('android').existsSync()) return;
    final p = _logger.progress('Downloading Android engine (android-arm64)');
    final ok = await manager.ensureAndroidEngine(
      flutterVersion: flutterVersion,
      force: force,
    );
    if (ok) {
      p.complete('Android engine ready');
    } else {
      p.fail('Android engine not fetched — run '
          '`fcp codepush setup --platform android` to retry.');
    }
  }

  Future<int> _listVersions(CodePushArtifactManager manager) async {
    final progress = _logger.progress('Fetching supported Flutter versions');
    final versions = await manager.fetchSupportedVersions();

    if (versions == null || versions.isEmpty) {
      progress.fail('Could not fetch version list from server.');
      return ExitCode.software.code;
    }

    progress.complete('${versions.length} version(s) available');
    _logger.info('');

    // Show current Flutter version for context.
    final current = manager.detectFlutterVersion();
    final cached = manager.listCachedVersions().toSet();

    _logger.info('Supported Flutter versions for code push:');
    _logger.info('');
    for (final entry in versions.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      final ver = entry.key;
      final markers = <String>[];
      if (ver == current) markers.add('current');
      if (cached.contains(ver)) markers.add('cached');
      final suffix = markers.isEmpty ? '' : '  (${markers.join(', ')})';
      _logger.info('  $ver$suffix');
    }

    _logger.info('');
    if (current != null && !versions.containsKey(current)) {
      _logger.warn(
        'Your current Flutter version ($current) is not yet supported.',
      );
    }
    _logger.info('');
    _logger.info(
      'For per-platform support (Android vs iOS), run '
      '`fcp codepush versions`.',
    );

    return ExitCode.success.code;
  }
}
