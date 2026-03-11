import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/binary_diff.dart';
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
            'Compile the current source to kernel and package as .vmcode before uploading.',
        defaultsTo: false,
      )
      ..addOption(
        'baseline',
        help: 'Path to the baseline snapshot for binary diffing.',
      )
      ..addOption(
        'signing-key',
        help: 'Path to RSA private key for signing the patch.',
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

    // If --build, compile kernel and package as .vmcode.
    final shouldBuild = argResults?['build'] as bool? ?? false;
    final buildService = CodePushBuildService(logger: _logger);

    if (shouldBuild) {
      final compileProgress = _logger.progress('Compiling kernel');
      final kernelPath = await buildService.compileKernel();
      if (kernelPath == null) {
        compileProgress.fail('Kernel compilation failed');
        return ExitCode.software.code;
      }
      compileProgress.complete('Kernel compiled');

      final kernelData = File(kernelPath).readAsBytesSync();

      // If baseline is provided, compute binary diff instead of full kernel.
      Uint8List payloadData;
      final baselinePath = argResults?['baseline'] as String?;
      if (baselinePath != null && File(baselinePath).existsSync()) {
        final diffProgress = _logger.progress('Computing binary diff');
        final baseline = File(baselinePath).readAsBytesSync();
        payloadData = bsdiff(baseline, Uint8List.fromList(kernelData));
        final savings = kernelData.length - payloadData.length;
        diffProgress.complete(
          'Diff: ${payloadData.length} bytes (saved ${savings > 0 ? savings : 0} bytes)',
        );
      } else {
        payloadData = Uint8List.fromList(kernelData);
        if (baselinePath != null) {
          _logger.warn('Baseline not found at $baselinePath, using full kernel.');
        }
      }

      // Sign if signing key is provided.
      Uint8List? signature;
      final signingKeyPath = argResults?['signing-key'] as String?;
      if (signingKeyPath != null) {
        final signProgress = _logger.progress('Signing patch');
        signature = await buildService.signPayload(payloadData, signingKeyPath);
        if (signature == null) {
          signProgress.fail('Signing failed');
          return ExitCode.software.code;
        }
        signProgress.complete('Signed (${signature.length} bytes)');
      }

      final packageProgress = _logger.progress('Packaging .vmcode');
      final vmcodeData = buildService.packageVmcode(payloadData, signature: signature);
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
