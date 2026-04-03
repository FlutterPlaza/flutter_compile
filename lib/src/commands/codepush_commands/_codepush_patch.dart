import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/binary_diff.dart';
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
        help: 'Path to the patch binary (.vmcode).',
      )
      ..addOption(
        'rollout',
        help: 'Rollout percentage (1-100).',
        defaultsTo: '100',
      )
      ..addFlag(
        'build',
        help:
            'Build the app with Flutter, extract snapshot, and package as .vmcode.',
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
      );
  }

  final Logger _logger;

  @override
  final String name = 'patch';
  @override
  final String description =
      'Upload a code push patch (requires paid subscription).';

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

      // Swap standard engine with code-push engine before building.
      final swapProgress = _logger.progress('Preparing code push build');
      final swapped = await buildService.swapEngine(
        buildPlatform: platform,
        flutterVersion: null,
        artifactManager: CodePushArtifactManager(logger: _logger),
      );
      if (swapped) {
        swapProgress.complete('Ready');
      } else {
        swapProgress.fail(
          'Code push build preparation failed.'
          'Run "fcp codepush setup" first.',
        );
      }

      // Build the app using Flutter's own compiler (handles dart:ui etc).
      final buildProgress = _logger.progress('Building ($platform)');
      final buildOk = await buildService.buildRelease(platform: platform);
      if (!buildOk) {
        buildProgress.fail('Build failed');
        return ExitCode.software.code;
      }
      buildProgress.complete('Build succeeded');

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

      // If baseline is provided, compute binary diff instead of full snapshot.
      Uint8List payloadData;
      final baselinePath = argResults?['baseline'] as String?;
      if (baselinePath != null && File(baselinePath).existsSync()) {
        final diffProgress = _logger.progress('Computing binary diff');
        final baseline = File(baselinePath).readAsBytesSync();
        payloadData = bsdiff(baseline, Uint8List.fromList(snapshotData));
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
      } else {
        _logger.warn(
          'No signing key found. Patch will be unsigned.\n'
          '  Run "fcp codepush init" to generate a key pair, or use '
          '--signing-key.',
        );
      }

      final packageProgress = _logger.progress('Packaging .vmcode');
      final vmcodeData =
          buildService.packageVmcode(payloadData, signature: signature);
      final vmcodePath = 'build/codepush/patch.vmcode';
      File(vmcodePath).writeAsBytesSync(vmcodeData);
      packageProgress.complete(
        'Packaged ${vmcodeData.length} bytes → $vmcodePath',
      );
    }

    // Resolve patch file.
    var patchPath = argResults?['patch-file'] as String?;
    if (patchPath == null || patchPath.isEmpty) {
      // Look for default patch output.
      final candidates = [
        'build/codepush/patch.vmcode',
        'build/patch.vmcode',
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
