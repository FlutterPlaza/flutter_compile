import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
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
        help: 'Target platform (e.g., darwin-arm64, linux-x64). '
            'Defaults to current platform.',
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
    final tool = await manager.ensureBuildTool();
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

    // Check if already cached.
    if (!force && manager.isVersionCached(flutterVersion)) {
      _logger.info(
        'Build artifacts already cached for Flutter $flutterVersion.',
      );
      _logger.info(
        '  Path: ${manager.versionDir(flutterVersion)}/${targetPlatform ?? manager.currentPlatform}',
      );
      await manager.saveActiveVersion(flutterVersion);
      _logger.success('Code push is ready.');
      return ExitCode.success.code;
    }

    // Check if this version is supported before attempting download.
    final checkProgress = _logger.progress(
      'Checking server for Flutter $flutterVersion artifacts',
    );
    final supported = await manager.isVersionSupported(flutterVersion);
    if (!supported) {
      checkProgress.fail(
        'Flutter $flutterVersion is not yet supported for code push.',
      );
      _logger.info('');
      _logger.info('Run `fcp codepush setup --list-versions` to see '
          'available Flutter versions.');
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

    // Save as active version.
    await manager.saveActiveVersion(flutterVersion);

    _logger.info('  Cached at: ${manager.versionDir(flutterVersion)}');

    // Ensure Dart SDK is available in the contribution Flutter repo.
    // This prevents the broken download when the repo has a custom
    // engine hash not in Google's infrastructure bucket.
    final home = Platform.environment['HOME'] ?? '/tmp';
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

    // Clean up other versions if requested.
    if (cleanup) {
      manager.cleanupOldVersions(keepVersion: flutterVersion);
    }

    _logger.success(
      'Code push is ready for Flutter $flutterVersion.',
    );
    return ExitCode.success.code;
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

    return ExitCode.success.code;
  }
}
