import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
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
        help: 'Target platform (apk, appbundle, ios, linux, macos, windows).',
      )
      ..addFlag(
        'build',
        help: 'Build the app in release mode before uploading.',
        defaultsTo: false,
      )
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK version this release was built with (e.g., 3.41.2). '
            'Auto-detected from "flutter --version" if not specified. '
            'Required for server-side patch compilation.',
      );
  }

  final Logger _logger;

  @override
  final String name = 'release';
  @override
  final String description = 'Upload a baseline release.';

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
        final match =
            RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(content);
        if (match != null) {
          version = match.group(1)?.trim();
        }
      }
      if (version == null || version.isEmpty) {
        _logger.err(
            'No version specified. Use --version or add one to pubspec.yaml.');
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
          'Cannot detect platform. Use --platform to specify (apk, appbundle, ios, linux, macos, windows).',
        );
        return ExitCode.usage.code;
      }

      final artifactManager = CodePushArtifactManager(logger: _logger);

      final prepProgress = _logger.progress('Preparing code push build');
      final prepared = await buildService.prepareCodePushBuild(
        buildPlatform: platform,
        flutterVersion: null,
        artifactManager: artifactManager,
      );
      if (prepared) {
        prepProgress.complete('Ready');
      } else {
        prepProgress.fail(
          'Code push build preparation failed. '
          'Run "fcp codepush setup" first.',
        );
      }

      final buildProgress = _logger.progress('Building release ($platform)');
      final buildOk = await buildService.buildRelease(
        platform: platform,
      );
      if (!buildOk) {
        buildProgress.fail('Build failed');
        return ExitCode.software.code;
      }
      buildProgress.complete('Build succeeded');

      final finalizeProgress = _logger.progress('Finalizing build');
      final finalized = await buildService.finalizeBuild(
        buildPlatform: platform,
        flutterVersion: null,
        artifactManager: artifactManager,
      );
      if (finalized.success) {
        finalizeProgress.complete('Build finalized');
      } else {
        finalizeProgress.fail(finalized.message ?? 'Finalization failed');
        final diagnostics = finalized.formatDiagnostics();
        if (diagnostics.isNotEmpty) {
          _logger.err(diagnostics);
        }
        return ExitCode.software.code;
      }
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

    final snapshotFile = File(snapshotPath);
    if (!snapshotFile.existsSync()) {
      _logger.err('Snapshot file not found: $snapshotPath');
      return ExitCode.software.code;
    }

    final snapshotData = snapshotFile.readAsBytesSync();
    _logger.detail('Snapshot size: ${snapshotData.length} bytes');

    // Resolve Flutter version for server-side compilation.
    var flutterVersion = argResults?['flutter-version'] as String?;
    if (flutterVersion == null || flutterVersion.isEmpty) {
      final flutter = buildService.findFlutterBin();
      if (flutter != null) {
        // Try --machine output first (structured JSON).
        final vResult = Process.runSync(flutter, ['--version', '--machine']);
        if (vResult.exitCode == 0) {
          try {
            final vJson = (vResult.stdout as String).trim();
            final match =
                RegExp(r'"frameworkVersion"\s*:\s*"([^"]+)"').firstMatch(vJson);
            flutterVersion = match?.group(1);
          } catch (_) {}
        }
        // Fallback: parse plain `flutter --version` output.
        if (flutterVersion == null || flutterVersion.isEmpty) {
          final plainResult = Process.runSync(flutter, ['--version']);
          if (plainResult.exitCode == 0) {
            final match = RegExp(r'Flutter (\d+\.\d+\.\d+)')
                .firstMatch(plainResult.stdout as String);
            flutterVersion = match?.group(1);
          }
        }
      }
      if (flutterVersion != null) {
        _logger.detail('Detected Flutter version: $flutterVersion');
      } else {
        _logger.warn(
          'Warning: Could not detect Flutter version. Server-side compilation '
          'will not be available for this release.',
        );
      }
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final versionSuffix =
        flutterVersion != null ? ' (Flutter $flutterVersion)' : '';
    final progress =
        _logger.progress('Creating release v$version for $appId$versionSuffix');

    try {
      final result = await client.createRelease(
        token: token,
        appId: appId,
        version: version,
        snapshotData: snapshotData,
        flutterVersion: flutterVersion,
      );

      final statusCode = result['status_code'] as int;

      if (statusCode == 403) {
        final serverError = result['error'] as String?;
        final upgradeUrl =
            result['upgrade_url'] as String? ?? 'flutterplaza.com/pricing';
        progress.fail(
          serverError != null
              ? '$serverError See $upgradeUrl'
              : 'Upload denied by server. See $upgradeUrl',
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
        _logger.info('  Release ID:      ${release['id']}');
        _logger.info('  Version:         ${release['version']}');
        _logger.info('  Hash:            ${release['snapshot_hash']}');
        if (release['flutter_version'] != null) {
          _logger.info('  Flutter version: ${release['flutter_version']}');
        }
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
