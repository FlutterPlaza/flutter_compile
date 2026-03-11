import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushReleaseSubCommand extends Command<int> {
  CodePushReleaseSubCommand(this._logger) {
    argParser
      ..addOption(
        'app-id',
        help: 'The app ID to create a release for.',
      )
      ..addOption(
        'version',
        abbr: 'v',
        help: 'The version string for this release (e.g., 1.0.0+1).',
      )
      ..addOption(
        'snapshot',
        help: 'Path to the AOT snapshot file (.so or .aot).',
      )
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Target platform (apk, ios, linux, macos, windows).',
      )
      ..addFlag(
        'build',
        help: 'Build the app in release mode before uploading.',
        defaultsTo: false,
      )
      ..addFlag(
        'deterministic',
        help: 'Re-run gen_snapshot with --stable_object_pool_indices for deterministic output.',
        defaultsTo: false,
      );
  }

  final Logger _logger;

  @override
  final String name = 'release';
  @override
  final String description =
      'Upload a baseline release (requires paid subscription).';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    // Resolve app ID.
    var appId = argResults?['app-id'] as String?;
    appId ??= await CodePushClient.getAppId();
    if (appId == null || appId.isEmpty) {
      _logger.err(
        'No app ID specified. Use --app-id or run "fcp config set codepush_app_id <id>".',
      );
      return ExitCode.usage.code;
    }

    // Resolve version.
    var version = argResults?['version'] as String?;
    if (version == null || version.isEmpty) {
      // Try to read from pubspec.yaml in current directory.
      final pubspec = File('pubspec.yaml');
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        final match = RegExp(r'^version:\s*(.+)$', multiLine: true)
            .firstMatch(content);
        if (match != null) {
          version = match.group(1)?.trim();
        }
      }
      if (version == null || version.isEmpty) {
        _logger.err('No version specified. Use --version or add one to pubspec.yaml.');
        return ExitCode.usage.code;
      }
      _logger.detail('Using version from pubspec.yaml: $version');
    }

    // If --build is set, build the app first.
    final shouldBuild = argResults?['build'] as bool? ?? false;
    final buildService = CodePushBuildService(logger: _logger);

    if (shouldBuild) {
      var platform = argResults?['platform'] as String?;
      platform ??= buildService.detectPlatform();
      if (platform == null) {
        _logger.err(
          'Cannot detect platform. Use --platform to specify (apk, ios, linux, macos, windows).',
        );
        return ExitCode.usage.code;
      }

      final buildProgress = _logger.progress('Building release ($platform)');
      final snapshotResult = await buildService.buildRelease(
        platform: platform,
      );
      if (snapshotResult == null) {
        buildProgress.fail('Build failed');
        return ExitCode.software.code;
      }
      buildProgress.complete('Build succeeded');
    }

    // Resolve snapshot path.
    var snapshotPath = argResults?['snapshot'] as String?;
    if (snapshotPath == null || snapshotPath.isEmpty) {
      // Auto-detect from build output.
      final platform = argResults?['platform'] as String?;
      snapshotPath = buildService.findSnapshotPath(platform ?? 'apk');
      if (snapshotPath == null) {
        _logger.err(
          'No snapshot found. Build your app in release mode first, or use --snapshot.',
        );
        return ExitCode.usage.code;
      }
      _logger.detail('Using snapshot: $snapshotPath');
    }

    // If --deterministic, re-run gen_snapshot with stable pool indices.
    final deterministic = argResults?['deterministic'] as bool? ?? false;
    if (deterministic) {
      final detProgress = _logger.progress('Re-running gen_snapshot (deterministic)');
      final detOutput = 'build/codepush/snapshot_deterministic.so';
      final detResult = await buildService.buildDeterministicSnapshot(
        inputPath: snapshotPath,
        outputPath: detOutput,
      );
      if (detResult == null) {
        detProgress.fail('Deterministic snapshot failed');
        return ExitCode.software.code;
      }
      snapshotPath = detResult;
      detProgress.complete('Deterministic snapshot ready');
    }

    final snapshotFile = File(snapshotPath);
    if (!snapshotFile.existsSync()) {
      _logger.err('Snapshot file not found: $snapshotPath');
      return ExitCode.software.code;
    }

    final snapshotData = snapshotFile.readAsBytesSync();
    _logger.detail('Snapshot size: ${snapshotData.length} bytes');

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = _logger.progress('Uploading release $version');

    try {
      final result = await client.createRelease(
        token: token,
        appId: appId,
        version: version,
        snapshotData: snapshotData,
      );

      final statusCode = result['status_code'] as int;

      if (statusCode == 403) {
        progress.fail(
          'Paid subscription required. Upgrade at ${result['upgrade_url'] ?? 'flutterplaza.com/pricing'}',
        );
        return ExitCode.software.code;
      }

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 201) {
        progress.fail('Error: ${result['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final release = result['release'] as Map<String, dynamic>?;
      progress.complete('Release $version uploaded');

      if (release != null) {
        _logger.info('  Release ID: ${release['id']}');
        _logger.info('  Version:    ${release['version']}');
        _logger.info('  Hash:       ${release['snapshot_hash']}');
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
