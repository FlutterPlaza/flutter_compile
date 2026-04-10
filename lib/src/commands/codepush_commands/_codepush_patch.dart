import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushPatchSubCommand extends Command<int> {
  CodePushPatchSubCommand(this._logger) {
    argParser
      ..addOption(
        'release-id',
        help: 'The release ID to patch against.',
      )
      ..addOption(
        'patch-file',
        help: 'Path to an existing patch file to upload.',
      )
      ..addOption(
        'rollout',
        help: 'Rollout percentage (1-100).',
        defaultsTo: '100',
      )
      ..addFlag(
        'build',
        help: 'Build the app with Flutter and produce a patch file.',
        defaultsTo: false,
      )
      ..addOption(
        'baseline',
        help: 'Path to the baseline snapshot for binary diffing.',
      )
      ..addOption(
        'signing-key',
        help: 'Path to RSA private key for signing the patch.',
      )
      ..addOption(
        'channel',
        help: 'Deployment channel (e.g., beta, production).',
        defaultsTo: 'production',
      )
      ..addOption(
        'platform',
        help: 'Target platform (apk, appbundle, ios, linux, macos, windows).',
      )
      ..addFlag(
        'unsigned',
        help: 'Allow uploading an unsigned patch (testing only).',
        negatable: false,
        defaultsTo: false,
      )
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK version this patch was built with (e.g., 3.41.2). '
            'Auto-detected from "flutter --version" if not specified, '
            'then falls back to codepush_engine_flutter_version in '
            '~/.flutter_compilerc. Required by the finalize step to locate '
            'the cached engine library.',
      );
  }

  final Logger _logger;

  @override
  final String name = 'patch';
  @override
  final String description = 'Upload a code push patch.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final releaseId = argResults?['release-id'] as String?;
    if (releaseId == null || releaseId.isEmpty) {
      _logger.err('--release-id is required.');
      return ExitCode.usage.code;
    }

    // If --build, use flutter build to compile, then extract the snapshot.
    final shouldBuild = argResults?['build'] as bool? ?? false;
    final buildService = CodePushBuildService(logger: _logger);

    if (shouldBuild) {
      var platform = argResults?['platform'] as String?;
      platform ??= buildService.detectPlatform();
      if (platform == null) {
        _logger.err(
          'Cannot detect platform. '
          'Use --platform to specify (apk, appbundle, ios, linux, macos, windows).',
        );
        return ExitCode.usage.code;
      }

      final artifactManager = CodePushArtifactManager(logger: _logger);

      final flutterVersion = await buildService.resolveFlutterVersion(
        explicit: argResults?['flutter-version'] as String?,
      );
      if (flutterVersion == null) {
        _logger.err(
          'Could not resolve Flutter SDK version. Pass --flutter-version '
          '<version>, ensure "flutter --version" works in this shell, or '
          'run "fcp codepush setup" to store a default engine version.',
        );
        return ExitCode.usage.code;
      }
      _logger.detail('Using Flutter version: $flutterVersion');

      final prepProgress = _logger.progress('Preparing code push build');
      final prepared = await buildService.prepareCodePushBuild(
        buildPlatform: platform,
        flutterVersion: flutterVersion,
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

      final buildProgress = _logger.progress('Building ($platform)');
      final buildOk = await buildService.buildRelease(platform: platform);
      if (!buildOk) {
        buildProgress.fail('Build failed');
        return ExitCode.software.code;
      }
      buildProgress.complete('Build succeeded');

      final finalizeProgress = _logger.progress('Finalizing build');
      final finalized = await buildService.finalizeBuild(
        buildPlatform: platform,
        flutterVersion: flutterVersion,
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

      // Extract the AOT snapshot from the build output.
      final snapshotPath = buildService.findSnapshotPath(platform);
      if (snapshotPath == null) {
        _logger.err(
          'Could not find snapshot in build output. '
          'Build succeeded but snapshot path is unknown for $platform.',
        );
        return ExitCode.software.code;
      }

      _logger.detail('Using snapshot: $snapshotPath');
      final snapshotData = File(snapshotPath).readAsBytesSync();

      // If baseline is provided, compute a binary diff via the build tool
      // instead of uploading the full snapshot.
      Uint8List payloadData;
      final baselinePath = argResults?['baseline'] as String?;
      if (baselinePath != null && File(baselinePath).existsSync()) {
        final diffProgress = _logger.progress('Computing binary diff');
        final baseline = File(baselinePath).readAsBytesSync();
        final diff = await buildService.diffBytes(
          baseline: Uint8List.fromList(baseline),
          updated: Uint8List.fromList(snapshotData),
          artifactManager: artifactManager,
        );
        if (diff == null) {
          diffProgress.fail('Binary diff failed');
          return ExitCode.software.code;
        }
        payloadData = diff;
        final savings = snapshotData.length - payloadData.length;
        diffProgress.complete(
          'Diff: ${payloadData.length} bytes '
          '(saved ${savings > 0 ? savings : 0} bytes)',
        );
      } else {
        payloadData = Uint8List.fromList(snapshotData);
        if (baselinePath != null) {
          _logger.warn(
            'Baseline not found at $baselinePath, using full snapshot.',
          );
        }
      }

      // Sign the patch. Auto-detect stored key if --signing-key not provided.
      // Signing is mandatory unless --unsigned is explicitly passed.
      final allowUnsigned = argResults?['unsigned'] as bool? ?? false;
      Uint8List? signature;
      var signingKeyPath = argResults?['signing-key'] as String?;
      signingKeyPath ??= await CodePushClient.getStoredSigningKey();
      if (signingKeyPath != null && signingKeyPath.isNotEmpty) {
        final signProgress = _logger.progress('Signing patch');
        signature = await buildService.signPayload(payloadData, signingKeyPath);
        if (signature == null) {
          signProgress.fail('Signing failed');
          return ExitCode.software.code;
        }
        signProgress.complete('Signed (${signature.length} bytes)');
      } else if (!allowUnsigned) {
        _logger.err(
          'No signing key found. Patches must be signed for production.\n'
          '  Run "fcp codepush init" to generate a key pair, or use '
          '--signing-key.\n'
          '  To bypass (testing only): --unsigned',
        );
        return ExitCode.software.code;
      } else {
        _logger.warn(
          'Uploading unsigned patch (--unsigned). '
          'Do NOT use in production.',
        );
      }

      final packageProgress = _logger.progress('Packaging patch');
      const patchOutputPath = 'build/codepush/patch.fcppatch';
      final packaged = await buildService.packagePayload(
        payload: payloadData,
        outputPath: patchOutputPath,
        artifactManager: artifactManager,
      );
      if (!packaged) {
        packageProgress.fail('Packaging failed.');
        return ExitCode.software.code;
      }
      packageProgress.complete('Patch ready → $patchOutputPath');
    }

    var patchPath = argResults?['patch-file'] as String?;
    if (patchPath == null || patchPath.isEmpty) {
      final candidates = [
        'build/codepush/patch.fcppatch',
        'build/patch.fcppatch',
      ];
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) {
          patchPath = candidate;
          break;
        }
      }
      if (patchPath == null) {
        _logger.err(
          'No patch file found. Use --build to compile, or --patch-file to specify.',
        );
        return ExitCode.usage.code;
      }
      _logger.detail('Using patch: $patchPath');
    }

    final patchFile = File(patchPath);
    if (!patchFile.existsSync()) {
      _logger.err('Patch file not found: $patchPath');
      return ExitCode.software.code;
    }

    final rolloutStr = argResults?['rollout'] as String? ?? '100';
    final rollout = int.tryParse(rolloutStr) ?? 100;
    final channel = argResults?['channel'] as String? ?? 'production';
    if (rollout < 1 || rollout > 100) {
      _logger.err('Rollout percentage must be between 1 and 100.');
      return ExitCode.usage.code;
    }

    final patchData = patchFile.readAsBytesSync();
    _logger.detail('Patch size: ${patchData.length} bytes');

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = _logger.progress(
      'Uploading patch${rollout < 100 ? ' ($rollout% rollout)' : ''}',
    );

    try {
      final result = await client.createPatch(
        token: token,
        releaseId: releaseId,
        patchData: patchData,
        rolloutPercentage: rollout,
        channel: channel,
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

      final patch = result['patch'] as Map<String, dynamic>?;
      progress.complete('Patch uploaded');

      if (patch != null) {
        _logger.info('  Patch ID:     ${patch['id']}');
        _logger.info('  Patch #:      ${patch['number']}');
        _logger.info('  Hash:         ${patch['patch_hash']}');
        _logger.info('  Rollout:      ${patch['rollout_percentage']}%');
        _logger.info('  Channel:      ${patch['channel']}');
        _logger.info('  Download URL: ${patch['patch_url']}');
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
