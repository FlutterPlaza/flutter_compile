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
      ..addOption('release-id', help: 'The release ID to patch against.')
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
      )
      ..addFlag(
        'swap-mode',
        help: 'iOS only. Alternative patch generation mode that '
            'enables runtime function replacement. Default: off.',
        negatable: false,
      )
      ..addMultiOption(
        'include-uri',
        help: 'iOS only. Additional library URI to include in the '
            'bytecode module (repeatable). For patch-side helper '
            'libraries not discovered automatically.',
      )
      ..addFlag(
        'allow-unguarded-release',
        help: 'Acknowledge patching an iOS release that was built '
            'without widget guarding (or without the interface '
            'freeze): silences the warning. Patches that add new '
            'widget subclasses will still fail on such a release.',
        negatable: false,
      );
  }

  final Logger _logger;

  /// Warn when the target [release] (its server JSON, or null when it
  /// could not be fetched) was recorded as built without the
  /// interface freeze or without widget guarding. Reads the
  /// `--allow-unguarded-release` acknowledgement itself so the flag
  /// link is testable with real parsed args. No platform gate: only
  /// iOS release builds ever attest these keys, so a definite value
  /// is itself proof this is an iOS release — a gate on the patch's
  /// own platform flag would make the warning unreachable for plain
  /// `--patch-file` uploads. Absent/null fields stay silent — every
  /// pre-metadata release, old server, or fetch failure is unknown,
  /// not unguarded. Public for tests ([run] cannot be cheaply
  /// exercised).
  void warnIfUnguardedRelease(Map<String, dynamic>? release) {
    if (release == null) return;
    final acknowledged =
        argResults?['allow-unguarded-release'] as bool? ?? false;
    if (acknowledged) return;
    // Tolerant "off" read: the deployed server stores and returns
    // real JSON booleans (verified live), but a string or int echo
    // from some future server must degrade to a FIRED warning, not a
    // silently inert feature. Only a definite off-shape warns.
    // ('0' is the string echo of the int echo — a tinyint column
    // serialized as text. 0.0 needs no clause: num equality already
    // makes it == 0. 'FALSE'/'off'/etc. stay deliberately unknown.)
    bool isOff(Object? value) =>
        value == false || value == 'false' || value == 0 || value == '0';
    if (isOff(release['interface_freeze'])) {
      // Freeze off implies guarding off too — warn once, naming the
      // root cause, not a flag the user never passed.
      _logger.warn(
        'This release was built without the interface freeze '
        '(--no-interface-freeze): it may not be reliably patchable, '
        'and patches that declare new widget subclasses will crash on '
        'it. Pass --allow-unguarded-release to acknowledge and '
        'silence this warning.',
      );
    } else if (isOff(release['extendable_widgets'])) {
      _logger.warn(
        'This release was built without widget guarding '
        '(--no-extendable-widgets): a patch that declares new widget '
        'subclasses — for example, a new screen — will crash on it. '
        'Pass --allow-unguarded-release to acknowledge and silence '
        'this warning.',
      );
    }
  }

  /// The release's stored `snapshot_hash`, or null when the value is
  /// unusable. Same rule as [warnIfUnguardedRelease]'s tolerant read:
  /// a server-shape surprise (non-String, empty, truncated) must
  /// degrade to the local fallback — never crash after the whole
  /// build, and never upload as a baseline identity no device can
  /// match. The 16-char floor rejects definite-looking garbage while
  /// admitting any real digest. Public for tests.
  String? baselineHashFrom(Map<String, dynamic>? release) {
    final rawHash = release?['snapshot_hash'];
    return (rawHash is String && rawHash.length >= 16) ? rawHash : null;
  }

  /// Read the target release and inspect it BEFORE any build: the
  /// null warn and the unguarded-release warn both fire here, where
  /// aborting is still cheap. Generous default deadline: this fetch
  /// also carries the release's stored baseline hash, and for a
  /// patch-file-only invocation there is no local fallback — so a
  /// timeout must be rare (30s tolerates a cold proxy handshake) and
  /// degrade like every other failure. Public for tests ([run]
  /// cannot be cheaply exercised), because this wire is the one
  /// place where deleting a call leaves the whole guard feature
  /// inert with every unit test still green.
  Future<Map<String, dynamic>?> readTargetRelease({
    required CodePushClient client,
    required String token,
    required String releaseId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _logger.detail('Reading release $releaseId…');
    final releaseInfo = await client
        .getRelease(token: token, releaseId: releaseId)
        .timeout(timeout, onTimeout: () => null);
    if (releaseInfo == null) {
      // Cheap to say NOW, expensive to discover after the build: a
      // typo'd release id, an expired login, an old server, and
      // being offline all collapse into this null.
      _logger.warn(
        'Could not read release $releaseId from the server (wrong '
        'id, expired login, offline, or an old server). Continuing '
        "— the upload will verify the release id, but the release's "
        'stored baseline hash could not be read: unless a local '
        'build supplies one, this patch uploads without the '
        'device-side baseline check.',
      );
    }
    warnIfUnguardedRelease(releaseInfo);
    return releaseInfo;
  }

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
    String? builtPlatform;
    CodePushClient? client;

    try {
      // Resolve the build platform BEFORE the release fetch: the
      // unguarded-release warning must not fire for a run that then
      // exits on argument validation — nothing was ever at risk.
      if (shouldBuild) {
        var resolvedPlatform = argResults?['platform'] as String?;
        resolvedPlatform ??= buildService.detectPlatform();
        if (resolvedPlatform == null) {
          _logger.err(
            'Cannot detect platform. '
            'Use --platform to specify (apk, appbundle, ios, linux, macos, windows).',
          );
          return ExitCode.usage.code;
        }
        builtPlatform = resolvedPlatform;
      }

      // Fetch the target release's metadata next — still ahead of any
      // build work: several minutes of building must not precede the
      // news that the target cannot safely take a widget-adding patch;
      // the acknowledgement flag should be a decision, not a post-hoc
      // apology. Best-effort: getRelease returns null on any failure
      // (old server, offline) and every consumer below degrades.
      final serverUrl = await CodePushClient.getServerUrl();
      client = CodePushClient(serverUrl: serverUrl);
      final releaseInfo = await readTargetRelease(
        client: client,
        token: token,
        releaseId: releaseId,
      );

      if (shouldBuild) {
        final platform = builtPlatform!;

        final artifactManager = CodePushArtifactManager(logger: _logger);

        final flutterVersion = await buildService.resolveFlutterVersion(
          explicit: argResults?['flutter-version'] as String?,
          buildPlatform: platform,
          artifactManager: artifactManager,
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
        String? iosPatchSourceImport;
        var iosSwapMode = false;
        var iosHelperImports = <String>[];

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

          iosSwapMode = argResults?['swap-mode'] as bool? ?? false;
          final generated = _writeGeneratedIosPatchTarget(
            patchSourcePath: patchSource,
            useImportWrapper: iosSwapMode,
          );
          if (generated == null) {
            _logger.err(
              'Failed to create the temporary iOS patch entry target under `lib/`.',
            );
            return ExitCode.software.code;
          }
          generatedIosTargetPath = generated;
          iosBuildTarget = generated;
          iosPatchSourceImport = importPathForPatchSource(patchSource);
          iosHelperImports = _discoverDirectHelpers(patchSource);
          if (iosHelperImports.isNotEmpty) {
            _logger.detail(
              'Discovered ${iosHelperImports.length} '
              'helper import(s) from patch source',
            );
          }
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
          artifactManager: artifactManager,
          flutterVersion: flutterVersion,
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

          // The release build's kernel is whole-program optimized and
          // must not feed the patch compiler: its call shapes are
          // specialized to the app that was just built, not to the app
          // being patched. Compile a dedicated patch kernel instead
          // (release defines, no whole-program optimization).
          final iosPatchTarget = generatedIosTargetPath;
          if (iosPatchTarget == null) {
            bytecodeProgress.fail('No iOS patch entry target');
            return ExitCode.software.code;
          }
          const patchKernelOutput = 'build/codepush/patch_kernel.dill';
          final kernelResult = await buildService.compilePatchKernel(
            targetPath: iosPatchTarget,
            outputDillPath: patchKernelOutput,
            dartDefines: dartDefines,
          );
          if (!kernelResult.success) {
            bytecodeProgress.fail(
              kernelResult.message ?? 'Patch kernel compile failed',
            );
            final diag = kernelResult.formatDiagnostics();
            if (diag.isNotEmpty) _logger.err(diag);
            return ExitCode.software.code;
          }
          const inputDill = patchKernelOutput;

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

          // Derive the entry URI so the bytecode compiler narrows its
          // output to only patch-relevant libraries.
          final entryUri = generatedIosTargetPath != null
              ? '$packagePrefix$kGeneratedIosPatchEntryFilename'
              : null;

          // In swap mode, include the patch source library so the swap
          // loop can replace its functions in the baseline AOT class.
          // In inline mode, the source is absorbed into the wrapper and
          // there's no separate library to include.
          //
          // In both modes, include any helper libraries discovered from
          // the patch source's direct relative imports.
          final explicitIncludes =
              argResults?['include-uri'] as List<String>? ?? const [];
          final includeUris = <String>{
            if (iosSwapMode && iosPatchSourceImport != null)
              '$packagePrefix$iosPatchSourceImport',
            for (final helper in iosHelperImports) '$packagePrefix$helper',
            ...explicitIncludes.where((u) => u.isNotEmpty),
          }.toList();

          final bcResult = await buildService.bytecodeFromKernel(
            inputDill: inputDill,
            packagePrefix: packagePrefix,
            host: artifactManager.currentPlatform,
            flutterVersion: flutterVersion,
            outputPath: bytecodeOutput,
            artifactManager: artifactManager,
            entryUri: entryUri,
            includeUris: includeUris,
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

      // Sign the raw payload inside the container and embed the
      // signature, so a signed app can verify the patch on device. The
      // same signature goes to the server, which verifies it over the
      // same payload bytes. Auto-detect the stored key if --signing-key
      // isn't passed. Signing is mandatory unless --unsigned is set.
      final artifactManagerForSigning = CodePushArtifactManager(
        logger: _logger,
      );
      final allowUnsigned = argResults?['unsigned'] as bool? ?? false;
      String? signatureBase64;
      var signingKeyPath = argResults?['signing-key'] as String?;
      signingKeyPath ??= await CodePushClient.getStoredSigningKey();
      if (signingKeyPath != null && signingKeyPath.isNotEmpty) {
        final signProgress = _logger.progress('Signing patch');
        signatureBase64 = await buildService.signPatchContainer(
          patchPath: patchPath,
          privateKeyPath: signingKeyPath,
          artifactManager: artifactManagerForSigning,
        );
        if (signatureBase64 == null) {
          signProgress.fail('Signing failed');
          return ExitCode.software.code;
        }
        signProgress.complete('Signed and embedded');
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

      // Read the container AFTER signing: the sign step rewrote the file
      // with the signature embedded, and the device must receive that
      // signed container (an unsigned one is rejected by a signed app).
      final patchData = patchFile.readAsBytesSync();
      _logger.detail('Patch size: ${patchData.length} bytes');

      // The baseline_hash must match what the DEVICE is running (the
      // release binary), not the binary we just built (post-edit).
      // The release was fetched before the build; WHEN the fetch
      // succeeded and the release stores a usable hash, it agrees
      // with the device's installed baseline — the fallback below
      // covers every other case (shape rules: [baselineHashFrom]).
      var baselineHash = baselineHashFrom(releaseInfo);

      if (baselineHash != null) {
        _logger.detail(
          'Using release baseline hash from server: '
          '${baselineHash.substring(0, 16)}…',
        );
      } else {
        // Fallback: compute from local build output. This path runs
        // when the release has no stored hash or the server lookup
        // fails. Candidates are gated by the patch's platform — a dev
        // box routinely holds both an iOS and an Android build under
        // build/, and hashing the other platform's artifact would store
        // an identity no target device can match. Only a DEFINITIVE
        // platform counts: the explicit --platform flag or the platform
        // this invocation just built. A directory-layout guess is not
        // definitive (nearly every Flutter app has an android/ dir), so
        // without one no local hash is computed at all — the patch
        // uploads without a hash (served, not gated), which is safer
        // than gating on the wrong platform's artifact in either
        // direction. On Android only the stripped, packaged libapp.so
        // may be hashed (what devices actually run); the
        // merged_native_libs copy this used to hash is pre-strip and
        // hashes differently.
        final patchPlatform =
            (argResults?['platform'] as String?) ?? builtPlatform;
        final isAndroidFallback =
            const {'apk', 'appbundle', 'android'}.contains(patchPlatform);
        final androidBaselineLib = isAndroidFallback
            ? buildService.findAndroidBaselineLibPath()
            : null;
        final iosBaselineBinary = patchPlatform == 'ios'
            ? buildService.findIosBaselineAppBinaryPath()
            : null;
        final candidateAppFrameworks = [
          if (iosBaselineBinary != null) iosBaselineBinary,
          if (androidBaselineLib != null) androidBaselineLib,
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
      // Re-surface the guard warning at the decision point: with
      // --build the early emission is minutes of build output up the
      // scrollback by now. (The early emission stays — it fires
      // where aborting is cheapest.)
      if (shouldBuild) {
        warnIfUnguardedRelease(releaseInfo);
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
          signature: signatureBase64,
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
      // force: a timed-out release fetch abandons its future but not
      // its socket; tear it down here instead of relying on the
      // entrypoint's exit().
      client?.close(force: true);
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
        final match = RegExp(
          r'^name:\s*([A-Za-z_][A-Za-z0-9_]*)\s*$',
        ).firstMatch(line);
        if (match != null) {
          return 'package:${match.group(1)}/';
        }
      }
    } catch (_) {
      // Fall through to null.
    }
    return null;
  }

  String? _resolveIosPatchSource({String? explicitPath}) {
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
    bool useImportWrapper = false,
  }) {
    final importPath = importPathForPatchSource(patchSourcePath);
    if (importPath == null) return null;

    final targetFile = File('lib/$kGeneratedIosPatchEntryFilename');
    targetFile.parent.createSync(recursive: true);
    targetFile.writeAsStringSync(
      buildGeneratedIosPatchEntrypoint(
        importPath: importPath,
        patchSourcePath: patchSourcePath,
        useImportWrapper: useImportWrapper,
      ),
      flush: true,
    );
    return targetFile.path;
  }

  /// Best-effort scan of the patch source file's direct relative
  /// imports. Returns lib-relative paths (e.g. `models/prayer.dart`)
  /// for each imported file that exists under `lib/`.
  ///
  /// Does NOT cover: `package:` self-imports, `export`, `part`, or
  /// transitive helpers. Use `--include-uri` for those.
  List<String> _discoverDirectHelpers(String patchSourcePath) {
    final sourceFile = File(patchSourcePath);
    if (!sourceFile.existsSync()) return const [];

    final sourceDir = sourceFile.parent.path;
    final libRoot = Directory('lib').absolute.path;
    var source = sourceFile.readAsStringSync();

    // Strip comments to avoid matching commented-out imports.
    source = source.replaceAll(RegExp(r'//[^\n]*'), '');
    source = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');

    final helpers = <String>[];

    // Match: import 'relative/path.dart'; or import "../path.dart";
    // Exclude: dart: and package: imports.
    final importPattern = RegExp(
      r'''import\s+['"](?!dart:|package:)([^'"]+)['"]''',
    );

    for (final match in importPattern.allMatches(source)) {
      final relativePath = match.group(1);
      if (relativePath == null) continue;

      // Resolve relative to the source file's directory.
      final resolved = File('$sourceDir/$relativePath');
      if (!resolved.existsSync()) continue;

      // Convert to lib-relative path.
      final absolute = resolved.absolute.path;
      if (!absolute.startsWith(libRoot)) continue;
      var libRelative = absolute.substring(libRoot.length);
      if (libRelative.startsWith('/')) {
        libRelative = libRelative.substring(1);
      }

      helpers.add(libRelative);
    }

    return helpers;
  }
}
