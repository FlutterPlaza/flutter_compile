import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/ios_patch_entry_target.dart';
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
      ..addMultiOption(
        'dart-define',
        help: 'Additional --dart-define values to forward to flutter build '
            'when --build is used. Repeat for multiple values.',
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
      )
      ..addOption(
        'package-prefix',
        help: 'iOS only. Package URI prefix identifying the user\'s '
            'app code (e.g. `package:fcptest/`). Only libraries '
            'whose URIs start with this prefix get compiled into the '
            'patch; everything else (Flutter framework, pub deps) '
            'is referenced symbolically. Auto-detected from the '
            'app\'s pubspec.yaml `name:` field if not specified.',
      )
      ..addOption(
        'patch-entry-file',
        help: 'iOS only. Path to the Dart file under `lib/` that defines '
            '`codePushPatch()`. If omitted, flutter_compile scans `lib/` '
            'and requires exactly one matching source file.',
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
    String? generatedIosTargetPath;
    CodePushClient? client;

    try {
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

        final dartDefines =
            (argResults?['dart-define'] as List<String>? ?? const <String>[])
                .where((value) => value.isNotEmpty)
                .toList();
        final extraBuildArgs = [
          for (final value in dartDefines) '--dart-define=$value',
        ];
        String? iosPackagePrefix;
        String? iosBuildTarget;

        if (platform == 'ios') {
          iosPackagePrefix = argResults?['package-prefix'] as String?;
          if (iosPackagePrefix == null || iosPackagePrefix.isEmpty) {
            iosPackagePrefix = _readPackagePrefixFromPubspec();
            if (iosPackagePrefix == null) {
              _logger.err(
                'Pass `--package-prefix <package:my_app/>` or run from '
                'an app directory containing a valid pubspec.yaml with '
                'a `name:` field.',
              );
              return ExitCode.software.code;
            }
            _logger.detail('Auto-detected --package-prefix: $iosPackagePrefix');
          }

          final patchEntryFile = argResults?['patch-entry-file'] as String?;
          final patchSource = _resolveIosPatchSource(
            explicitPath: patchEntryFile,
          );
          if (patchSource == null) {
            return ExitCode.software.code;
          }

          final generated = _writeGeneratedIosPatchTarget(
            patchSourcePath: patchSource,
          );
          if (generated == null) {
            _logger.err(
              'Failed to create the temporary iOS patch entry target under `lib/`.',
            );
            return ExitCode.software.code;
          }
          generatedIosTargetPath = generated;
          iosBuildTarget = generated;
          _logger.detail('Using iOS patch source: $patchSource');
          _logger.detail('Generated iOS patch target: $generated');
        }

        final prepProgress = _logger.progress('Preparing code push build');
        final prepared = await buildService.prepareCodePushBuild(
          buildPlatform: platform,
          flutterVersion: flutterVersion,
          artifactManager: artifactManager,
          skipToolPrepare: platform == 'ios',
        );
        if (prepared) {
          prepProgress.complete('Ready');
        } else {
          prepProgress.fail(
            'Code push build preparation failed. '
            'Run "fcp codepush setup" first.',
          );
          return ExitCode.software.code;
        }

        final buildProgress = _logger.progress('Building ($platform)');
        final buildOk = await buildService.buildRelease(
          platform: platform,
          target: iosBuildTarget,
          extraArgs: [
            if (platform == 'ios') '--no-codesign',
            ...extraBuildArgs,
          ],
        );
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

        // Payload production takes a different path per platform.
        String payloadPath;
        if (platform == 'ios') {
          final bytecodeProgress = _logger.progress('Building iOS patch');
          const bytecodeOutput = 'build/codepush/patch.bytecode';

          final inputDill = buildService.findSnapshotPath('ios');
          if (inputDill == null) {
            bytecodeProgress.fail('Could not locate iOS build input');
            _logger.err(
              'Expected a build artifact under .dart_tool/flutter_build/. '
              'Run `flutter build ios --release` first.',
            );
            return ExitCode.software.code;
          }

          // Package URI prefix: either user-supplied or auto-detected
          // from pubspec.yaml.
          var packagePrefix = iosPackagePrefix;
          if (packagePrefix == null || packagePrefix.isEmpty) {
            packagePrefix = _readPackagePrefixFromPubspec();
            if (packagePrefix == null) {
              bytecodeProgress.fail('Could not auto-detect package prefix');
              _logger.err(
                'Pass `--package-prefix <package:my_app/>` or run from '
                'an app directory containing a valid pubspec.yaml with '
                'a `name:` field.',
              );
              return ExitCode.software.code;
            }
            _logger.detail('Auto-detected --package-prefix: $packagePrefix');
          }

          final bcResult = await buildService.bytecodeFromKernel(
            inputDill: inputDill,
            packagePrefix: packagePrefix,
            host: artifactManager.currentPlatform,
            flutterVersion: flutterVersion,
            outputPath: bytecodeOutput,
            artifactManager: artifactManager,
          );
          if (!bcResult.success) {
            bytecodeProgress.fail(bcResult.message ?? 'iOS patch build failed');
            final diag = bcResult.formatDiagnostics();
            if (diag.isNotEmpty) _logger.err(diag);
            return ExitCode.software.code;
          }
          bytecodeProgress.complete('iOS patch ready → $bytecodeOutput');
          payloadPath = bytecodeOutput;
        } else {
          final located = buildService.findSnapshotPath(platform);
          if (located == null) {
            _logger.err(
              'Could not find patch payload in build output for '
              '$platform.\n'
              '  Re-run `fcp codepush setup` if build tools are stale.',
            );
            return ExitCode.software.code;
          }
          payloadPath = located;
        }

        _logger.detail('Using patch payload: $payloadPath');
        final snapshotData = File(payloadPath).readAsBytesSync();

        // Fast-fail format validation before the server upload.
        final magicError = CodePushBuildService.validatePayloadMagic(
          snapshotData,
          platform,
        );
        if (magicError != null) {
          _logger.err('Refusing to upload: $magicError');
          return ExitCode.software.code;
        }

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

      // Sign the packaged patch bytes (not the raw payload). The server
      // will verify the signature against exactly these bytes.
      // Auto-detect stored key if --signing-key isn't passed. Signing is
      // mandatory unless --unsigned is explicitly set.
      final buildServiceForSigning = CodePushBuildService(logger: _logger);
      final allowUnsigned = argResults?['unsigned'] as bool? ?? false;
      Uint8List? signature;
      var signingKeyPath = argResults?['signing-key'] as String?;
      signingKeyPath ??= await CodePushClient.getStoredSigningKey();
      if (signingKeyPath != null && signingKeyPath.isNotEmpty) {
        final signProgress = _logger.progress('Signing patch');
        signature = await buildServiceForSigning.signPayload(
          Uint8List.fromList(patchData),
          signingKeyPath,
        );
        if (signature == null) {
          signProgress.fail('Signing failed');
          return ExitCode.software.code;
        }
        signProgress.complete('Signed (${signature.length} bytes)');
      } else if (!allowUnsigned) {
        _logger.err(
          'No signing key found. Patches must be signed for production.\n'
          '  Run "fcp codepush keys generate" to create a key pair, then\n'
          '  "fcp codepush keys register" to upload the public key, or\n'
          '  pass --signing-key <path>.\n'
          '  To bypass (testing only): --unsigned',
        );
        return ExitCode.software.code;
      } else {
        _logger.warn(
          'Uploading unsigned patch (--unsigned). '
          'Do NOT use in production.',
        );
      }

      final serverUrl = await CodePushClient.getServerUrl();
      client = CodePushClient(serverUrl: serverUrl);

      // The baseline_hash must match what the DEVICE is running (the
      // release binary), not the binary we just built (post-edit).
      // When --release-id is provided, fetch the release's stored
      // hash from the server so hashes always agree with the
      // device's installed baseline.
      String? baselineHash;
      try {
        baselineHash = await client.getReleaseHash(
          token: token,
          releaseId: releaseId,
        );
      } catch (_) {
        // Best-effort — fall through to local computation.
      }

      if (baselineHash != null) {
        _logger.detail(
          'Using release baseline hash from server: '
          '${baselineHash.substring(0, 16)}…',
        );
      } else {
        // Fallback: compute from local build output (pre-existing
        // behavior). This path runs when the release has no stored
        // hash or the server lookup fails.
        final candidateAppFrameworks = [
          'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App',
          'build/app/intermediates/merged_native_libs/release/out/lib/arm64-v8a/libapp.so',
        ];
        for (final candidate in candidateAppFrameworks) {
          final file = File(candidate);
          if (file.existsSync()) {
            final bytes = file.readAsBytesSync();
            baselineHash = sha256.convert(bytes).toString();
            _logger.detail(
              'Baseline hash (local fallback): '
              '${baselineHash.substring(0, 16)}…',
            );
            break;
          }
        }
      }
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
          signature: signature == null ? null : base64Encode(signature),
          baselineHash: baselineHash,
        );

        final statusCode = result['status_code'] as int;

        if (statusCode == 403) {
          final serverError = result['error'] as String?;
          final serverMessage = result['message'] as String?;
          final docsUrl = result['docs_url'] as String?;
          final upgradeUrl =
              result['upgrade_url'] as String? ?? 'flutterplaza.com/pricing';
          progress.fail(serverError ?? 'Upload denied by server.');
          if (serverMessage != null) {
            _logger.err(serverMessage);
          }
          if (docsUrl != null) {
            _logger.info('  Docs: $docsUrl');
          } else if (serverError != null) {
            _logger.info('  See $upgradeUrl');
          }
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

        // Migration banner: the server replies with a `signature_enforcement`
        // block whenever it grandfathers an unsigned patch (app has no
        // public key on file). Tell the user loudly, once, how to flip on
        // mandatory verification.
        final enforcement =
            result['signature_enforcement'] as Map<String, dynamic>?;
        if (enforcement != null) {
          _logger
            ..info('')
            ..warn('⚠  Signature enforcement: ${enforcement['status']}')
            ..warn('   ${enforcement['message']}')
            ..info('   Action:  ${enforcement['action']}');
          final docsUrl = enforcement['docs_url'];
          if (docsUrl is String) {
            _logger.info('   Docs:    $docsUrl');
          }
        }

        return ExitCode.success.code;
      } catch (e) {
        progress.fail('Failed: $e');
        return ExitCode.software.code;
      }
    } finally {
      if (generatedIosTargetPath != null) {
        try {
          final generated = File(generatedIosTargetPath);
          if (generated.existsSync()) {
            generated.deleteSync();
          }
        } catch (_) {
          // Best-effort cleanup only.
        }
      }
      client?.close();
    }
  }

  /// Read `pubspec.yaml` from the current directory and return the
  /// app's package URI prefix in the form `package:<name>/`. Returns
  /// null when pubspec.yaml is missing or has no `name:` field.
  String? _readPackagePrefixFromPubspec() {
    final file = File('pubspec.yaml');
    if (!file.existsSync()) return null;
    try {
      for (final line in file.readAsLinesSync()) {
        final match =
            RegExp(r'^name:\s*([A-Za-z_][A-Za-z0-9_]*)\s*$').firstMatch(line);
        if (match != null) {
          return 'package:${match.group(1)}/';
        }
      }
    } catch (_) {
      // Fall through to null.
    }
    return null;
  }

  String? _resolveIosPatchSource({
    String? explicitPath,
  }) {
    if (explicitPath != null && explicitPath.isNotEmpty) {
      if (!File(explicitPath).existsSync()) {
        _logger.err('Patch entry source not found: $explicitPath');
        return null;
      }
      final importPath = importPathForPatchSource(explicitPath);
      if (importPath == null) {
        _logger.err(
          '--patch-entry-file must point to a Dart file under `lib/`.',
        );
        return null;
      }
      return File(explicitPath).path;
    }

    final candidates = findCodePushPatchSourceCandidates();
    if (candidates.isEmpty) {
      _logger.err(
        'Could not find a Dart file under `lib/` that defines `codePushPatch()`.\n'
        '  Pass --patch-entry-file <lib/...dart> to specify it explicitly.',
      );
      return null;
    }
    if (candidates.length > 1) {
      final list = candidates.map((path) => '  - $path').join('\n');
      _logger.err(
        'Found multiple iOS patch sources defining `codePushPatch()`:\n$list\n'
        '  Pass --patch-entry-file <lib/...dart> to choose one.',
      );
      return null;
    }
    return candidates.first;
  }

  String? _writeGeneratedIosPatchTarget({
    required String patchSourcePath,
  }) {
    final importPath = importPathForPatchSource(patchSourcePath);
    if (importPath == null) return null;

    final targetFile = File('lib/$kGeneratedIosPatchEntryFilename');
    targetFile.parent.createSync(recursive: true);
    targetFile.writeAsStringSync(
      buildGeneratedIosPatchEntrypoint(
        importPath: importPath,
        patchSourcePath: patchSourcePath,
      ),
      flush: true,
    );
    return targetFile.path;
  }
}
