import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

import 'codepush_artifact_manager.dart';
import 'codepush_client.dart';
import 'exception.dart';
import 'interface_freeze_constants.dart' as freeze_files;

/// Outcome of a build-tool subprocess step.
///
/// Methods like [CodePushBuildService.finalizeBuild] used to return a bare
/// `bool` and swallow stderr, leaving callers with nothing to report on
/// failure. This struct carries the exit code, command line, and captured
/// stdio so the caller can log a useful diagnostic next to its
/// `progress.fail(...)` line.
class BuildStepResult {
  const BuildStepResult({
    required this.success,
    this.message,
    this.command,
    this.exitCode,
    this.stdout,
    this.stderr,
  });

  final bool success;

  /// Short, user-facing summary. Non-null on failure.
  final String? message;

  /// Full subprocess argv (including the tool path at index 0). Null when
  /// the step failed before the subprocess ran (e.g. tool not downloaded).
  final List<String>? command;

  /// Subprocess exit code. Null when the subprocess never ran.
  final int? exitCode;

  final String? stdout;
  final String? stderr;

  /// Multi-line diagnostic dump suitable for `_logger.err(...)` right after
  /// a `progress.fail(...)` call. Empty when there is nothing to add beyond
  /// the short [message]. Never includes ANSI codes.
  String formatDiagnostics() {
    final buf = StringBuffer();
    if (exitCode != null) {
      buf.writeln('  exit code: $exitCode');
    }
    if (command != null && command!.isNotEmpty) {
      final tool = command!.first.split(Platform.pathSeparator).last;
      final display = [tool, ...command!.skip(1)];
      buf.writeln('  command:   ${display.join(' ')}');
    }
    final err = stderr?.trim() ?? '';
    if (err.isNotEmpty) {
      buf.writeln('  stderr:');
      for (final line in err.split('\n')) {
        buf.writeln('    $line');
      }
    }
    final out = stdout?.trim() ?? '';
    if (out.isNotEmpty) {
      buf.writeln('  stdout:');
      for (final line in out.split('\n')) {
        buf.writeln('    $line');
      }
    }
    return buf.toString().trimRight();
  }
}

/// Result of the Android pre-build engine preparation step.
///
/// [environment] must be present on the `flutter build` process so the
/// produced app packages the code-push engine; [engineSha256] is the
/// engine library's checksum, used to verify the built artifact.
class AndroidEnginePrep {
  const AndroidEnginePrep({
    required this.environment,
    required this.engineSha256,
  });

  final Map<String, String> environment;
  final String engineSha256;
}

/// Build service for code push operations.
///
/// Only high-level, non-proprietary glue lives here:
///   - locate the Flutter / Dart tools on PATH
///   - run `flutter build`
///   - compute SHA-256 hashes and sign payloads with RSA
///   - thin Process wrappers around the private build tool binary
class CodePushBuildService {
  CodePushBuildService({required Logger logger}) : _logger = logger;

  final Logger _logger;

  /// Whether the last Android [buildRelease] installed and verified the
  /// code-push engine as part of the build itself (in which case the
  /// post-build finalize step has nothing left to do).
  bool _androidEngineVerified = false;

  /// Test seam for [finalizeBuild]'s Android short-circuit; production
  /// code must only set this through [buildRelease]'s verification.
  void debugSetAndroidEngineVerified({required bool value}) {
    _androidEngineVerified = value;
  }

  /// Find the `flutter` executable.
  String? findFlutterBin() {
    final result = Process.runSync('which', ['flutter']);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    return null;
  }

  /// Parse the first line of `flutter --version` stdout into a bare
  /// version string.
  ///
  /// Example inputs:
  ///   "Flutter 3.41.2 • channel stable • https://..." → "3.41.2"
  ///   "Flutter 3.27.0-0.1.pre • channel beta • ..."   → "3.27.0-0.1.pre"
  ///
  /// Returns null when the input is empty or the first line does not
  /// start with `Flutter <version>`.
  static String? parseFlutterVersionOutput(String stdout) {
    if (stdout.isEmpty) return null;
    final firstLine = stdout.split('\n').first.trim();
    final match = RegExp(r'^Flutter\s+(\S+)').firstMatch(firstLine);
    return match?.group(1);
  }

  /// Detect the installed Flutter SDK version by running `flutter --version`
  /// and passing its stdout through [parseFlutterVersionOutput]. Returns
  /// null if `flutter` is not on PATH, the subprocess fails twice, or the
  /// output can't be parsed.
  ///
  /// The subprocess is retried once: a transient `flutter --version`
  /// failure (first run after a cache clean, filesystem contention) must
  /// not silently hand version resolution to the stored fallback, which
  /// may point at a different platform lane than the current build. The
  /// retry also covers a run whose output fails to parse — unlikely to
  /// change on a second run, but cheap and keeps the loop uniform.
  ///
  /// [runProcess] is a test seam; production callers omit it.
  Future<String?> detectFlutterVersion({
    Future<ProcessResult> Function(String executable, List<String> args)?
        runProcess,
  }) async {
    final flutterBin = findFlutterBin();
    if (flutterBin == null) return null;
    final run = runProcess ?? Process.run;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await run(flutterBin, ['--version']);
        if (result.exitCode == 0) {
          final parsed = parseFlutterVersionOutput(result.stdout as String);
          if (parsed != null) return parsed;
        }
      } catch (_) {
        // Fall through to the retry (or to null after the last attempt).
      }
    }
    return null;
  }

  /// Map a `flutter build` platform to the device-target artifact
  /// platform tracked by the platform-aware version manifest, or null
  /// for platforms the manifest does not track (desktop targets).
  static String? artifactTargetForBuildPlatform(String buildPlatform) {
    switch (buildPlatform) {
      case 'ios':
        return 'ios-arm64';
      case 'apk':
      case 'appbundle':
      case 'android':
        return 'android-arm64';
      default:
        return null;
    }
  }

  /// Validate the stored-config fallback version for the platform being
  /// built. Called by [resolveFlutterVersion] when resolution reaches the
  /// `~/.flutter_compilerc` fallback; public so tests can drive the
  /// fallback branch directly (detection cannot be forced to fail in a
  /// test environment with a working `flutter` on PATH).
  ///
  /// Returns [stored] when it is usable for [buildPlatform], or null —
  /// with an actionable error logged — when the platform-aware manifest
  /// is available and says [stored] has no artifacts for this platform.
  /// When the manifest is unavailable (offline, old server) the stored
  /// value is accepted unchecked, preserving the old behavior.
  Future<String?> guardStoredVersion({
    required String stored,
    String? buildPlatform,
    CodePushArtifactManager? artifactManager,
  }) async {
    _logger.warn(
      'flutter --version was unavailable; falling back to the stored '
      'engine version $stored from ~/.flutter_compilerc.',
    );
    final targetPlatform = buildPlatform == null
        ? null
        : artifactTargetForBuildPlatform(buildPlatform);
    if (targetPlatform == null || artifactManager == null) return stored;
    final support = await artifactManager.fetchPlatformSupport();
    if (support == null) return stored;
    final versionEntry = support[stored];
    if (versionEntry != null && versionEntry.containsKey(targetPlatform)) {
      return stored;
    }
    if (versionEntry == null) {
      _logger.err(
        'The stored engine version $stored (from ~/.flutter_compilerc) is '
        'not a supported code push version, so it cannot be used for this '
        'build. Pass --flutter-version <version> or ensure '
        '"flutter --version" works in this shell.',
      );
    } else {
      _logger.err(
        'The stored engine version $stored (from ~/.flutter_compilerc) has '
        'no $buildPlatform artifacts, so it cannot be used for this build. '
        'It was likely stored by a setup for a different platform. Pass '
        '--flutter-version <version>, ensure "flutter --version" works in '
        'this shell, or run "fcp codepush setup" for this platform.',
      );
    }
    return null;
  }

  /// Resolve the Flutter SDK version to use for code push build steps.
  ///
  /// Precedence:
  ///   1. [explicit] — typically from a `--flutter-version` CLI flag.
  ///   2. `flutter --version` output ([detectFlutterVersion], retried once).
  ///   3. `codepush_engine_flutter_version` in `~/.flutter_compilerc`
  ///      ([CodePushClient.getStoredEngineFlutterVersion]) — validated
  ///      against the platform-aware version manifest via
  ///      [guardStoredVersion] when [buildPlatform] and [artifactManager]
  ///      are provided, so a stored value from a different platform lane
  ///      fails with an actionable error instead of a confusing download
  ///      failure later.
  ///
  /// Returns null when all three sources yield an empty/missing value, or
  /// when the stored fallback is rejected for [buildPlatform]. Callers
  /// should treat null as a user-facing error and tell the user to pass
  /// `--flutter-version` explicitly or run `fcp codepush setup`.
  Future<String?> resolveFlutterVersion({
    String? explicit,
    String? buildPlatform,
    CodePushArtifactManager? artifactManager,
  }) async {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final detected = await detectFlutterVersion();
    if (detected != null && detected.isNotEmpty) return detected;
    final stored = await CodePushClient.getStoredEngineFlutterVersion();
    if (stored == null || stored.isEmpty) return null;
    return guardStoredVersion(
      stored: stored,
      buildPlatform: buildPlatform,
      artifactManager: artifactManager,
    );
  }

  /// Find the `dart` executable.
  String? findDartBin() {
    final result = Process.runSync('which', ['dart']);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    return null;
  }

  /// Build a Flutter app in release mode.
  ///
  /// On iOS, guarantees a matched custom engine pair in the built app:
  ///
  /// 1. Installs the custom overlay (Flutter.framework + gen_snapshot)
  ///    into the Flutter SDK cache before the build.
  /// 2. Records SHA-256 hashes of both custom artifacts.
  /// 3. After the build, checks whether `flutter build` reset either
  ///    artifact:
  ///    - gen_snapshot drifted → the built snapshot is poisoned,
  ///      framework-only repair cannot fix it. Re-overlay and rebuild.
  ///    - Framework drifted but gen_snapshot stayed → copy the correct
  ///      framework into the built Runner.app (repairable).
  ///    - Both match → built app is valid.
  Future<bool> buildRelease({
    required String platform,
    List<String> extraArgs = const [],
    String? target,
    CodePushArtifactManager? artifactManager,
    String? flutterVersion,
  }) async {
    final flutter = findFlutterBin();
    if (flutter == null) {
      _logger.err('Flutter not found on PATH.');
      return false;
    }

    final isIos =
        platform == 'ios' && artifactManager != null && flutterVersion != null;

    String? expectedGenSnapshotSha;
    String? expectedFrameworkSha;
    String? sdkGenSnapshotPath;
    String? sdkFrameworkPath;

    // --- iOS: overlay before build + record expected SHAs ---
    if (isIos) {
      _logger.detail('Ensuring iOS engine overlay before build...');
      final overlayOk = await artifactManager.installOverlaysIntoFlutterSdk(
        flutterVersion: flutterVersion,
        platform: artifactManager.currentPlatform,
      );
      if (!overlayOk) {
        _logger.err(
          'Failed to install iOS engine overlay. '
          'Run "fcp codepush setup --force" and retry.',
        );
        return false;
      }

      final flutterRoot = _findActiveFlutterRoot();
      if (flutterRoot != null) {
        final engineCache = '$flutterRoot/bin/cache/artifacts/engine';
        sdkGenSnapshotPath = '$engineCache/ios-release/gen_snapshot_arm64';
        sdkFrameworkPath = '$engineCache/ios-release/'
            'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter';

        expectedGenSnapshotSha = _sha256OfFile(File(sdkGenSnapshotPath));
        expectedFrameworkSha = _sha256OfFile(File(sdkFrameworkPath));
        _logger.detail(
          'Recorded custom artifact SHAs before build:\n'
          '  gen_snapshot: ${expectedGenSnapshotSha?.substring(0, 16)}...\n'
          '  Framework:    ${expectedFrameworkSha?.substring(0, 16)}...',
        );
      }
    }

    // --- Android: prepare the engine BEFORE the build ---
    //
    // The engine library that ships in the APK/AAB is chosen while the
    // build runs; rewriting build outputs afterwards does not change
    // what was packaged. The build tool sets up the build environment
    // so the produced app packages the code-push engine, and the
    // artifact is verified after the build. A preparation failure fails
    // the build — never fall through to a silently-stock app.
    final isAndroid =
        platform == 'apk' || platform == 'appbundle' || platform == 'android';
    _androidEngineVerified = false;
    AndroidEnginePrep? androidPrep;
    if (isAndroid) {
      if (artifactManager == null || flutterVersion == null) {
        // Never fall through to a silently-stock Android build: a
        // missing parameter is a caller bug, not a reason to skip the
        // engine preparation and verification.
        _logger.err(
          'Android builds require artifactManager and flutterVersion '
          'so the produced app can be verified as code-push capable.',
        );
        return false;
      }
      androidPrep = await prepareAndroidEngineBuild(
        flutterVersion: flutterVersion,
        artifactManager: artifactManager,
      );
      if (androidPrep == null) return false;
    }

    // --- Run flutter build ---
    final args = [
      'build',
      platform,
      '--release',
      if (target != null && target.isNotEmpty) ...['--target', target],
      ...extraArgs,
    ];
    _logger.detail('Running: flutter ${args.join(' ')}');

    final process = await Process.start(
      flutter,
      args,
      mode: ProcessStartMode.inheritStdio,
      environment: androidPrep?.environment,
    );
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      _logger.err('Flutter build failed with exit code $exitCode');
      return false;
    }

    // --- Android: verify the built artifact packages the engine ---
    if (androidPrep != null) {
      final artifact = _findBuiltAndroidArtifact(platform);
      if (artifact == null) {
        _logger.err(
          'Build succeeded but no Android artifact was found to verify. '
          'Expected an APK under build/app/outputs/flutter-apk or an '
          'app bundle under build/app/outputs/bundle.',
        );
        return false;
      }
      if (!androidArchiveContainsEngine(
        archivePath: artifact,
        expectedSha256: androidPrep.engineSha256,
      )) {
        _logger.err(
          'The built app does not contain the code-push engine '
          '($artifact). Run "fcp codepush setup --force" and rebuild.',
        );
        return false;
      }
      _logger.detail('Verified code-push engine in $artifact.');
      _androidEngineVerified = true;
    }

    // --- iOS: validate + repair after build ---
    if (isIos &&
        expectedGenSnapshotSha != null &&
        expectedFrameworkSha != null &&
        sdkGenSnapshotPath != null &&
        sdkFrameworkPath != null) {
      final postBuildGenSnapshotSha = _sha256OfFile(File(sdkGenSnapshotPath));
      final genSnapshotDrifted =
          postBuildGenSnapshotSha != expectedGenSnapshotSha;

      if (genSnapshotDrifted) {
        // gen_snapshot was reset to stock during the build. The built
        // App.framework/App was compiled with the wrong gen_snapshot —
        // framework-only repair cannot fix this. Must re-overlay and
        // rebuild.
        _logger.warn(
          'flutter build reset gen_snapshot to stock. '
          'Re-overlaying and rebuilding...',
        );
        final reOverlayOk = await artifactManager.installOverlaysIntoFlutterSdk(
          flutterVersion: flutterVersion,
          platform: artifactManager.currentPlatform,
        );
        if (!reOverlayOk) {
          _logger.err(
            'Failed to re-install iOS engine overlay after drift. '
            'Run "fcp codepush setup --force" and retry.',
          );
          return false;
        }
        // Rebuild with the restored overlay.
        _logger.detail('Re-running flutter build with restored overlay...');
        final retryProcess = await Process.start(
          flutter,
          args,
          mode: ProcessStartMode.inheritStdio,
        );
        final retryExit = await retryProcess.exitCode;
        if (retryExit != 0) {
          _logger.err('Retry build failed with exit code $retryExit');
          return false;
        }
        // Verify gen_snapshot stayed this time.
        final retryGenSha = _sha256OfFile(File(sdkGenSnapshotPath));
        if (retryGenSha != expectedGenSnapshotSha) {
          _logger.err(
            'gen_snapshot was reset again during rebuild. '
            'flutter build is actively overwriting the custom engine. '
            'Cannot produce a valid baseline app.\n'
            'Workaround: set FCP_CODEPUSH_IOS_ENGINE_DIR to point at '
            'your engine build output and rebuild.',
          );
          return false;
        }
      }

      // Check if the framework in the built app matches.
      final builtFramework = File(
        'build/ios/iphoneos/Runner.app/Frameworks/Flutter.framework/Flutter',
      );
      if (builtFramework.existsSync()) {
        final builtFrameworkSha = _sha256OfFile(builtFramework);
        if (builtFrameworkSha != expectedFrameworkSha) {
          // Framework drifted but gen_snapshot stayed — repairable.
          _logger.warn(
            'Built app framework does not match custom engine. '
            'Copying correct framework into built app...',
          );
          // Re-overlay SDK cache if needed.
          final sdkFrameworkSha = _sha256OfFile(File(sdkFrameworkPath));
          if (sdkFrameworkSha != expectedFrameworkSha) {
            await artifactManager.installOverlaysIntoFlutterSdk(
              flutterVersion: flutterVersion,
              platform: artifactManager.currentPlatform,
            );
          }
          // Copy framework into built app.
          final source = File(sdkFrameworkPath);
          if (!source.existsSync()) {
            _logger.err('Custom framework not found at $sdkFrameworkPath');
            return false;
          }
          builtFramework.writeAsBytesSync(source.readAsBytesSync());

          // Verify repair.
          final repairedSha = _sha256OfFile(builtFramework);
          if (repairedSha != expectedFrameworkSha) {
            _logger.err('Framework repair failed — SHA mismatch after copy.');
            return false;
          }
          _logger.detail('Built app framework repaired successfully.');

          // The byte copy invalidated the framework's code signature AND
          // the app's seal over it — a device install is rejected
          // (0xe800801c) until both are re-signed. Sign with the identity
          // the app was already built with; an unsigned (--no-codesign)
          // build is left alone.
          if (!_resignAfterFrameworkSwap('build/ios/iphoneos/Runner.app')) {
            return false;
          }
        } else {
          _logger.detail('Built app validated — custom engine pair matched.');
        }
      }
    }

    return true;
  }

  /// Compute SHA-256 of a file, or return null if it doesn't exist.
  static String? _sha256OfFile(File file) {
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    return sha256.convert(bytes).toString();
  }

  /// Locate the active Flutter SDK root directory by resolving the
  /// `flutter` binary path and walking up to the SDK root.
  /// Public wrapper so commands can locate the SDK root for probes.
  String? findFlutterRootForProbe() => _findActiveFlutterRoot();

  static String? _findActiveFlutterRoot() {
    final which = Process.runSync('which', ['flutter']);
    if (which.exitCode != 0) return null;
    final bin = (which.stdout as String).trim();
    if (bin.isEmpty) return null;
    try {
      final resolved = File(bin).resolveSymbolicLinksSync();
      // flutter binary lives at <sdk>/bin/flutter → parent.parent = sdk root
      return File(resolved).parent.parent.path;
    } on FileSystemException {
      return null;
    }
  }

  /// Return the path to the build input used by the patch pipeline
  /// for [platform], or null if no candidate exists.
  String? findSnapshotPath(String platform) {
    if (platform == 'ios') {
      final buildDir = Directory('.dart_tool/flutter_build');
      if (!buildDir.existsSync()) return null;
      File? newest;
      DateTime? newestMtime;
      try {
        for (final entry in buildDir.listSync()) {
          if (entry is! Directory) continue;
          final dill = File('${entry.path}/app.dill');
          if (!dill.existsSync()) continue;
          final m = dill.statSync().modified;
          if (newestMtime == null || m.isAfter(newestMtime)) {
            newest = dill;
            newestMtime = m;
          }
        }
      } catch (_) {
        return null;
      }
      return newest?.path;
    }

    final Map<String, List<String>> platformPaths = {
      'apk': [
        'build/app/intermediates/flutter/release/app.so',
        'build/app/intermediates/stripped_native_libs/release/out/lib/arm64-v8a/libapp.so',
        'build/app/intermediates/stripped_native_libs/release/out/lib/armeabi-v7a/libapp.so',
        'build/app/intermediates/flutter/release/arm64-v8a/app.so',
        'build/app/intermediates/flutter/release/armeabi-v7a/app.so',
        'build/app/outputs/flutter-apk/app-release.apk',
      ],
      'appbundle': ['build/app/intermediates/flutter/release/app.so'],
      'linux': [
        'build/linux/x64/release/bundle/lib/libapp.so',
        'build/linux/arm64/release/bundle/lib/libapp.so',
      ],
      'macos': [
        'build/macos/Build/Products/Release/Runner.app/Contents/Frameworks/App.framework/App',
      ],
      'windows': ['build/windows/x64/runner/Release/app.so'],
    };

    final candidates = platformPaths[platform] ?? [];
    candidates.addAll([
      'build/app/intermediates/flutter/release/app.so',
      'build/linux/x64/release/bundle/lib/libapp.so',
    ]);

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }

    return null;
  }

  /// Extracts the signing identity from `codesign -dvv` output: the
  /// first `Authority=` line names the leaf certificate, which is the
  /// string `codesign --sign` accepts. Returns `'-'` for ad-hoc
  /// signatures (no Authority lines) and null when the output shows no
  /// signature at all, an unresolvable certificate chain
  /// (`Authority=(unavailable)` — signing with that literal fails with
  /// a misleading 'no identity found'), or nothing recognizable.
  static String? parseCodesignIdentity(String output) {
    if (output.contains('code object is not signed at all')) return null;
    for (final line in output.split('\n')) {
      final t = line.trim();
      if (t.startsWith('Authority=')) {
        final v = t.substring('Authority='.length).trim();
        if (v == '(unavailable)') return null;
        if (v.isNotEmpty) return v;
      }
      if (t == 'Signature=adhoc') return '-';
    }
    return null;
  }

  /// Re-signs `Flutter.framework` and re-seals the outer app after the
  /// framework bytes were replaced post-build. Without this a device
  /// install is rejected with 0xe800801c: the framework's signature no
  /// longer matches its bytes, and the app's seal no longer matches the
  /// framework. Uses the identity the app was already built with; an
  /// unsigned (--no-codesign) app is left unsigned.
  bool _resignAfterFrameworkSwap(String appPath) {
    final probe = Process.runSync('codesign', ['-dvv', appPath]);
    final probeOut = '${probe.stdout}\n${probe.stderr}';
    if (probe.exitCode != 0 &&
        probeOut.contains('code object is not signed at all')) {
      _logger.detail(
        'Built app is unsigned — skipping re-sign after framework repair.',
      );
      return true;
    }
    final identity = parseCodesignIdentity(probeOut);
    if (identity == null) {
      _logger.err(
        'Could not determine the signing identity of the built app, so the '
        'repaired framework cannot be re-signed and a device would refuse '
        'the install. Re-sign manually (codesign --force --sign <identity> '
        '$appPath/Frameworks/Flutter.framework, then the app) or rebuild.\n'
        'codesign reported:\n$probeOut',
      );
      return false;
    }
    final steps = <List<String>>[
      [
        '--force',
        '--sign',
        identity,
        '$appPath/Frameworks/Flutter.framework',
      ],
      [
        '--force',
        '--sign',
        identity,
        '--preserve-metadata=identifier,entitlements,flags',
        appPath,
      ],
    ];
    for (final args in steps) {
      final r = Process.runSync('codesign', args);
      if (r.exitCode != 0) {
        _logger.err(
          'codesign failed (exit ${r.exitCode}) for ${args.last}:\n'
          '${r.stderr}',
        );
        return false;
      }
    }
    final verify = Process.runSync(
      'codesign',
      ['--verify', '--deep', '--strict', appPath],
    );
    if (verify.exitCode != 0) {
      _logger.err(
        'Signature verification failed after the framework re-sign:\n'
        '${verify.stderr}',
      );
      return false;
    }
    _logger.detail('Re-signed Flutter.framework and re-sealed the app.');
    return true;
  }

  /// Whether a release without a platform signal must demand an
  /// explicit `--platform`: no explicit flag, nothing built this run,
  /// and the project is dual-platform (both `android/` and `ios/`
  /// exist). Applies to `--snapshot` releases too: directory detection
  /// probes `android/` first, so an intended iOS release would
  /// otherwise silently classify as Android — skipping the iOS
  /// baseline-identity requirement — and a release creates a server
  /// record, which deserves an explicit choice.
  static bool releaseNeedsExplicitPlatform({
    required String? explicitPlatform,
    required String? builtPlatform,
    required bool hasAndroidDir,
    required bool hasIosDir,
  }) =>
      explicitPlatform == null &&
      builtPlatform == null &&
      hasAndroidDir &&
      hasIosDir;

  /// The built iOS baseline binary — `App.framework/App` inside the
  /// release app — or null when no release build output exists. Both
  /// `flutter build ios` output (`build/ios/iphoneos`) and
  /// `flutter build ipa` output (the xcarchive) are recognized; the
  /// newest wins when both exist.
  ///
  /// This is the file the release upload must carry on iOS: it is the
  /// binary devices hash for the baseline check, and it is a few MB.
  /// The kernel that [findSnapshotPath] falls back to is the whole
  /// app's intermediate representation — tens of MB on real apps, over
  /// the upload size cap (HTTP 413) — and its hash matches nothing any
  /// device computes.
  /// [projectRoot] anchors the search; the default probes the invoking
  /// directory (the CLI's normal mode). Tests pass a temp dir so they
  /// never mutate the process-global Directory.current, which is a
  /// chdir(2) and races concurrent test isolates.
  String? findIosBaselineAppBinaryPath({String projectRoot = '.'}) {
    final candidates = [
      'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App',
      'build/ios/archive/Runner.xcarchive/Products/Applications/'
          'Runner.app/Frameworks/App.framework/App',
    ].map((rel) => projectRoot == '.' ? rel : '$projectRoot/$rel');
    String? newest;
    DateTime? newestMtime;
    for (final candidate in candidates) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      final mtime = file.statSync().modified;
      if (newestMtime == null || mtime.isAfter(newestMtime)) {
        newest = candidate;
        newestMtime = mtime;
      }
    }
    return newest;
  }

  /// Path of the Android release AOT library exactly as it ships to
  /// devices: the stripped `libapp.so` that gets packaged into the
  /// APK/AAB. This is the file whose SHA-256 matches what an installed
  /// app can compute from its own package, so it is the only correct
  /// source for release/baseline hashing on Android.
  ///
  /// The pre-strip copies (`intermediates/flutter/release/**/app.so`,
  /// `merged_native_libs/**/libapp.so`) are the same size but not the
  /// same bytes — the strip step rewrites the file in place — so
  /// hashing those produces a value no installed device can match.
  ///
  /// A release stores a single baseline identity, and with arm64-v8a
  /// preferred that is the arm64 identity. On a multi-ABI upload an
  /// armeabi-v7a device runs different bytes and will not match it —
  /// which is correct: patches are built for arm64 and must not be
  /// delivered to other ABIs.
  ///
  /// Returns null when no Android release build output is present.
  ///
  /// [projectRoot] anchors the search; the default probes the invoking
  /// directory (the CLI's normal mode). Tests pass a temp dir so they
  /// never mutate the process-global Directory.current.
  String? findAndroidBaselineLibPath({String projectRoot = '.'}) {
    const abis = ['arm64-v8a', 'armeabi-v7a'];
    const strippedRoot = 'build/app/intermediates/stripped_native_libs/release';
    String anchored(String rel) =>
        projectRoot == '.' ? rel : '$projectRoot/$rel';
    // Known layouts first: AGP 8 inserts the strip task name into the
    // path; older AGP wrote directly under out/.
    for (final abi in abis) {
      for (final path in [
        anchored(
            '$strippedRoot/stripReleaseDebugSymbols/out/lib/$abi/libapp.so'),
        anchored('$strippedRoot/out/lib/$abi/libapp.so'),
      ]) {
        if (File(path).existsSync()) return path;
      }
    }
    // Fallback: scan the stripped tree so a future AGP layout change
    // degrades to a search instead of a miss.
    final root = Directory(anchored(strippedRoot));
    if (!root.existsSync()) return null;
    try {
      // Stat each candidate once (a vanished file just drops out), then
      // sort newest-first so the tiebreak between several task dirs is
      // deterministic and picks the freshest build output.
      final libsWithMtime = <(File, DateTime)>[];
      for (final entry in root.listSync(recursive: true)) {
        if (entry is! File || entry.uri.pathSegments.last != 'libapp.so') {
          continue;
        }
        try {
          libsWithMtime.add((entry, entry.statSync().modified));
        } catch (_) {
          // Raced with a build clean — skip this candidate.
        }
      }
      libsWithMtime.sort((a, b) => b.$2.compareTo(a.$2));
      final libs = [for (final (file, _) in libsWithMtime) file];
      for (final abi in abis) {
        for (final lib in libs) {
          if (lib.uri.pathSegments.contains(abi)) return lib.path;
        }
      }
    } catch (_) {
      // Unreadable build tree — treat as absent.
    }
    return null;
  }

  /// Verify the first bytes of a patch payload match the expected
  /// format for [platform]. Returns `null` on pass; a short error
  /// string on fail.
  static String? validatePayloadMagic(List<int> payload, String platform) {
    if (payload.length < 4) {
      return 'Patch payload is too small to be valid '
          '(got ${payload.length} bytes).';
    }

    bool headerEquals(List<int> expected) {
      for (var i = 0; i < expected.length; i++) {
        if (payload[i] != expected[i]) return false;
      }
      return true;
    }

    // Per-platform expected headers. Values are stable format
    // identifiers for the platform's patch artifact — kept private.
    const iosHeader = <int>[0x33, 0x43, 0x42, 0x44];
    const macHeaderLe = <int>[0xCF, 0xFA, 0xED, 0xFE];
    const macHeaderBe = <int>[0xFE, 0xED, 0xFA, 0xCF];
    const elfHeader = <int>[0x7F, 0x45, 0x4C, 0x46];

    final ok = switch (platform) {
      'ios' => headerEquals(iosHeader),
      'macos' => headerEquals(macHeaderLe) || headerEquals(macHeaderBe),
      _ => headerEquals(elfHeader),
    };
    if (ok) return null;

    return 'Patch payload for $platform is not in the expected '
        'format. Upgrade flutter_compile to the latest version and '
        'rebuild the patch.';
  }

  /// Signs a packaged patch container in place and returns the base64
  /// RSA-SHA256 signature to forward to the server.
  ///
  /// Delegates to the build tool's `sign` step, which signs the raw
  /// payload inside the container (the exact bytes the device runtime
  /// and the server both verify) and embeds the signature so a signed
  /// app can load the patch. Returns null on any failure.
  Future<String?> signPatchContainer({
    required String patchPath,
    required String privateKeyPath,
    required CodePushArtifactManager artifactManager,
  }) async {
    if (!File(privateKeyPath).existsSync()) {
      _logger.err('Signing key not found: $privateKeyPath');
      return null;
    }
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) return null;

    // Sign a temp copy and swap it in on success, so a mid-sign failure
    // never leaves a partially-rewritten container on disk. The whole
    // body is guarded so any I/O or process error (unreadable patch,
    // a tool binary that's present but not executable / wrong arch / on
    // a noexec mount → ProcessException) returns null with a clear
    // message, honoring the "null on any failure" contract.
    final tmp = File('$patchPath.signing');
    try {
      File(patchPath).copySync(tmp.path);
      final result = Process.runSync(tool, [
        'sign',
        '--patch',
        tmp.path,
        '--signing-key',
        privateKeyPath,
      ]);
      if (result.exitCode != 0) {
        // An old cached tool has no `sign` subcommand; point the user at
        // the refresh rather than a bare tool error.
        _logger.err(
          'Signing failed: ${(result.stderr as String).trim()}\n'
          '  If this persists, refresh the build tool: '
          'fcp codepush setup --force',
        );
        return null;
      }
      final signatureBase64 = (result.stdout as String).trim();
      if (signatureBase64.isEmpty) {
        _logger.err('Signing produced no signature.');
        return null;
      }
      // The tool must print only the base64 signature; validate it so a
      // stray stdout line can't corrupt what we forward to the server.
      try {
        base64Decode(signatureBase64);
      } on FormatException {
        _logger.err('Signing produced malformed output.');
        return null;
      }
      tmp.renameSync(patchPath);
      return signatureBase64;
    } on Exception catch (e) {
      _logger.err('Signing failed: $e');
      return null;
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  /// Generate an RSA keypair for code push signing.
  Future<(String, String)?> generateSigningKey(String outputDir) async {
    final dir = Directory(outputDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final privatePath = '$outputDir/codepush_private.pem';
    final publicPath = '$outputDir/codepush_public.pem';

    var result = Process.runSync('openssl', [
      'genrsa',
      '-out',
      privatePath,
      '2048',
    ]);
    if (result.exitCode != 0) {
      _logger.err('Key generation failed: ${result.stderr}');
      return null;
    }

    result = Process.runSync('openssl', [
      'rsa',
      '-in',
      privatePath,
      '-pubout',
      '-out',
      publicPath,
    ]);
    if (result.exitCode != 0) {
      _logger.err('Public key extraction failed: ${result.stderr}');
      return null;
    }

    _logger.detail('Generated signing keypair:');
    _logger.detail('  Private: $privatePath');
    _logger.detail('  Public:  $publicPath');
    return (privatePath, publicPath);
  }

  /// Compute SHA-256 hash of data, returned as hex string.
  String computeHash(List<int> data) {
    return sha256.convert(data).toString();
  }

  /// Get the platform string from the current project.
  String? detectPlatform() {
    if (Directory('android').existsSync()) return 'apk';
    if (Directory('ios').existsSync()) return 'ios';
    if (Directory('linux').existsSync()) return 'linux';
    if (Directory('macos').existsSync()) return 'macos';
    if (Directory('windows').existsSync()) return 'windows';
    return null;
  }

  /// Run the prepare step of the build tool.
  Future<bool> prepareCodePushBuild({
    required String buildPlatform,
    String? flutterVersion,
    required CodePushArtifactManager artifactManager,
    bool skipToolPrepare = false,
  }) async {
    if (buildPlatform == 'ios') {
      if (flutterVersion == null || flutterVersion.isEmpty) {
        _logger.err('Flutter version is required to prepare an iOS fcp build.');
        return false;
      }
      final overlaysInstalled =
          await artifactManager.installOverlaysIntoFlutterSdk(
        flutterVersion: flutterVersion,
        platform: buildPlatform,
      );
      if (!overlaysInstalled) {
        _logger.err(
          'Failed to install the iOS fcp engine overlays into the active Flutter SDK.',
        );
        return false;
      }
    }

    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      _logger.err('Build tool not available. Run "fcp codepush setup" first.');
      return false;
    }
    if (skipToolPrepare) {
      return true;
    }
    final result = Process.runSync(tool, ['prepare', buildPlatform]);
    if (result.exitCode != 0) {
      _logger.err('Build preparation failed.');
    }
    return result.exitCode == 0;
  }

  /// Produce the iOS patch payload for [inputDill] by invoking the
  /// private build tool. [packagePrefix] filters which libraries
  /// from the input are included. [entryUri], when provided, narrows
  /// the output to only the entry library and patch-relevant
  /// libraries. iOS-only.
  Future<BuildStepResult> bytecodeFromKernel({
    required String inputDill,
    required String packagePrefix,
    required String host,
    required String flutterVersion,
    required String outputPath,
    required CodePushArtifactManager artifactManager,
    String target = 'flutter',
    String? entryUri,
    List<String> includeUris = const [],
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      return const BuildStepResult(
        success: false,
        message: 'Build tool not available. '
            'Run "fcp codepush setup" first to download it.',
      );
    }

    File(outputPath).parent.createSync(recursive: true);

    final args = <String>[
      'bytecode',
      '--host',
      host,
      '--flutter-version',
      flutterVersion,
      '--target',
      target,
      '--input-dill',
      inputDill,
      '--package-prefix',
      packagePrefix,
      '--output',
      outputPath,
      if (entryUri != null && entryUri.isNotEmpty) ...['--entry-uri', entryUri],
      for (final uri in includeUris)
        if (uri.isNotEmpty) ...['--include-uri', uri],
    ];
    final result = Process.runSync(tool, args);
    return BuildStepResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0 ? null : 'iOS patch build failed.',
      command: [tool, ...args],
      exitCode: result.exitCode,
      stdout: result.stdout as String?,
      stderr: result.stderr as String?,
    );
  }

  /// Front-end argument list for [compilePatchKernel]. Kept as a
  /// separate pure function so tests can assert the whole-program
  /// optimization flags stay absent.
  static List<String> patchKernelCompilerArgs({
    required String sdkRoot,
    required String packagesPath,
    required String outputDillPath,
    required String targetPath,
    List<String> dartDefines = const [],
    String? depfilePath,
  }) {
    return <String>[
      '--sdk-root',
      sdkRoot,
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=true',
      '--delete-tostring-package-uri=dart:ui',
      '--delete-tostring-package-uri=package:flutter',
      for (final define in dartDefines) '-D$define',
      '--packages',
      packagesPath,
      '--output-dill',
      outputDillPath,
      // The source closure of the compile — what lets the caller
      // verify a requested include URI is actually present in the
      // input before the module build silently ignores it.
      if (depfilePath != null) ...['--depfile', depfilePath],
      '--verbosity=error',
      targetPath,
    ];
  }

  /// gen_snapshot options required on iOS code push release builds.
  ///
  /// A release compiled without these can ship an app whose compiled
  /// code is not reliably callable from a delivered patch, which fails
  /// at run time. Applied by `fcp codepush release --build` on iOS only;
  /// patch builds are unaffected (their build output is not shipped).
  static const String kIosReleaseGenSnapshotOptions = '--no_use_register_cc';

  /// Return [extraArgs] with `--extra-gen-snapshot-options` carrying
  /// [kIosReleaseGenSnapshotOptions].
  ///
  /// Appends the argument when absent; merges into an existing
  /// `--extra-gen-snapshot-options=<list>` occurrence otherwise, since
  /// `flutter build` expects a single comma-separated list and a second
  /// occurrence would replace the first. Kept as a separate pure
  /// function so tests can pin the exact argv shape.
  static List<String> withIosReleaseGenSnapshotOptions(
    List<String> extraArgs,
  ) {
    const prefix = '--extra-gen-snapshot-options=';
    final merged = [...extraArgs];
    final index = merged.indexWhere((arg) => arg.startsWith(prefix));
    if (index < 0) {
      return merged..add('$prefix$kIosReleaseGenSnapshotOptions');
    }
    final existing = merged[index].substring(prefix.length);
    final options = existing.split(',').where((o) => o.isNotEmpty).toList();
    if (!options.contains(kIosReleaseGenSnapshotOptions)) {
      options.add(kIosReleaseGenSnapshotOptions);
    }
    merged[index] = '$prefix${options.join(',')}';
    return merged;
  }

  /// `dart:` libraries whose public call shapes are frozen in iOS
  /// release builds (see [buildIosInterfaceFreezeYaml]). Always safe to
  /// list: every entry ships in the product platform kernel, so it is
  /// present in every compile. Scoped to the surface app patches
  /// realistically call — each listed library is retained whole in the
  /// built app, so growing this list grows the shipped binary.
  static const List<String> kIosInterfaceFreezeDartLibraries = [
    'dart:core',
    'dart:async',
    'dart:collection',
    'dart:convert',
    'dart:math',
    'dart:typed_data',
    'dart:ui',
  ];

  /// `package:flutter` libraries frozen WHEN the app's compile actually
  /// contains them ([flutterLibrariesFromClosure]). Listing a library
  /// the compile does not contain hard-fails the build, so these are
  /// candidates, not unconditional entries — a widgets-only app must
  /// not have material/cupertino forced in.
  static const List<String> kIosInterfaceFreezeFlutterCandidates = [
    'package:flutter/foundation.dart',
    'package:flutter/widgets.dart',
    'package:flutter/material.dart',
    'package:flutter/cupertino.dart',
    'package:flutter/services.dart',
  ];

  /// Parse the package name out of pubspec content. Handles optional
  /// single/double quotes and trailing comments; returns null when no
  /// valid name line exists.
  static String? parsePubspecName(String pubspecContent) {
    final match = RegExp(
      '''^name:\\s*['"]?([A-Za-z0-9_]+)['"]?\\s*(#.*)?\$''',
      multiLine: true,
    ).firstMatch(pubspecContent);
    return match?.group(1);
  }

  /// Placeholder for escaped spaces while splitting depfile entries.
  static const String _depfileSpace = '\u0000';

  /// Parse a Makefile-style depfile (`out: src src...`) written by the
  /// front-end into the set of source paths, unescaping `\ `.

  static Set<String> parseDepfileSources(
    String depfileContent, {
    bool? windowsPaths,
  }) {
    final colon = depfileContent.indexOf(': ');
    if (colon < 0) return const {};
    final body = depfileContent
        .substring(colon + 2)
        .replaceAll('\\\n', ' ')
        .replaceAll(r'\ ', _depfileSpace);
    return body
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .map((s) => s.replaceAll(_depfileSpace, ' '))
        // Normalize separators once here so every closure consumer
        // (app-library mapping, framework detection, extendable gate)
        // sees '/' paths regardless of host toolchain. Windows entries
        // may double their backslashes under Make escaping, so runs of
        // the resulting '/' are collapsed too.
        .map((p) => _normalizePath(p, windows: windowsPaths))
        .toSet();
  }

  /// Whether Dart source [content] is a `part of` file (not a library).
  /// Scans directive position only — comments and blank lines are
  /// skipped, so a "part of" inside a string literal or doc text deeper
  /// in the file cannot misclassify a real library.
  static bool dartSourceIsPart(String content) {
    var inBlockComment = false;
    for (var line in content.split('\n')) {
      line = line.replaceFirst('﻿', '').trim();
      if (inBlockComment) {
        final end = line.indexOf('*/');
        if (end < 0) continue;
        line = line.substring(end + 2).trim();
      }
      inBlockComment = false;
      while (line.startsWith('/*')) {
        final end = line.indexOf('*/', 2);
        if (end < 0) {
          inBlockComment = true;
          line = '';
          break;
        }
        line = line.substring(end + 2).trim();
      }
      if (line.isEmpty || line.startsWith('//')) continue;
      // First significant line: only directives can precede code, so
      // this decides. `library x;`, annotations, and comments may come
      // before `part of`, but never executable code.
      if (line.startsWith('part of ') ||
          line.startsWith('part of;') ||
          line == 'part of') {
        return true;
      }
      if (line.startsWith('library ') ||
          line.startsWith('@') ||
          line.startsWith('library;')) {
        continue;
      }
      return false;
    }
    return false;
  }

  /// Canonical path normalization: on Windows-shaped input, separators
  /// to '/' (Make-escaping doubles backslashes there); slash runs
  /// collapsed everywhere. The parser and every defensive consumer use
  /// THIS so the sites cannot drift.
  ///
  /// The host is a PARAMETER (defaulting to the running platform, like
  /// [isAbsoluteSourcePath]'s purity): translation applies only to
  /// Windows paths, so a POSIX project root containing a literal
  /// backslash keeps working — the backslash only becomes a skip when
  /// it would have to enter a package URI (the import-safe charset
  /// check names it). Windows shapes stay testable from any host via
  /// the `windows:`/`windowsPaths:` overrides. The run-collapse folds
  /// a Windows UNC prefix (`\\server\share`) into `/server/share`, so
  /// UNC project roots are unsupported on the Windows leg — moot for
  /// the iOS release flow, which never runs on a Windows host.
  static final RegExp _slashRuns = RegExp('/{2,}');

  static String _normalizePath(String p, {bool? windows}) {
    final translated =
        (windows ?? Platform.isWindows) ? p.replaceAll(r'\', '/') : p;
    return translated.replaceAll(_slashRuns, '/');
  }

  /// Separator-normalize closure entries so every consumer agrees even
  /// when handed a closure that skipped [parseDepfileSources].
  static Iterable<String> _normalizeClosure(
    Set<String> closurePaths, {
    bool? windows,
  }) =>
      closurePaths.map((p) => _normalizePath(p, windows: windows));

  static final RegExp _windowsDrivePrefix = RegExp(r'^[A-Za-z]:[/\\]');

  /// Whether [path] is absolute on any supported host (POSIX `/…` or a
  /// Windows drive-letter form). Pure so any platform's leg can test
  /// the other's shapes.
  static bool isAbsoluteSourcePath(String path) =>
      path.startsWith('/') || _windowsDrivePrefix.hasMatch(path);

  /// Map the compile closure's source paths to the app's own library
  /// URIs. Only files that the compile actually contains are listed —
  /// dead files, flavor entrypoints, and untaken conditional-import
  /// branches never enter the freeze, so they can never fail the build.
  /// Part files are excluded ([dartSourceIsPart]); URIs with characters
  /// outside the import-safe set are skipped and reported via [onSkip].
  /// Scope: this maps the main package's own `lib/` only; dependency
  /// packages are mapped separately by
  /// [dependencyPackageLibrariesFromClosure] and both feed the freeze
  /// (an unfrozen library's shapes are specialized, its library
  /// dictionary is emptied in release builds, and patches cannot
  /// reach its members).
  static List<String> appLibrariesFromClosure({
    required Set<String> closurePaths,
    required String projectRoot,
    required String packageName,
    void Function(String path, String reason)? onSkip,
    bool? windowsPaths,
  }) {
    // Closure paths are separator-normalized (see [parseDepfileSources]
    // and the per-entry normalization below); normalize the root the
    // same way so Windows roots match.
    final root = _normalizePath(projectRoot, windows: windowsPaths);
    final libPrefixes = <String>{
      '$root/lib/',
      // The front-end may write resolved (symlink-free) paths...
      '${_normalizePath(_tryResolve(projectRoot), windows: windowsPaths)}'
          '/lib/',
      // ...or relative ones, depending on version.
      'lib/',
    };
    final safe = RegExp(r'^[A-Za-z0-9_\-./]+$');
    final uris = <String>[];
    for (final rawPath in closurePaths) {
      final path = _normalizePath(rawPath, windows: windowsPaths);
      if (!path.endsWith('.dart')) continue;
      final prefix = libPrefixes.firstWhere(
        path.startsWith,
        orElse: () => '',
      );
      if (prefix.isEmpty) continue;
      final rel = path.substring(prefix.length);
      if (rel.split('/').any((seg) => seg.startsWith('.'))) continue;
      if (!safe.hasMatch(rel)) {
        onSkip?.call(path, 'unsupported characters in path');
        continue;
      }
      final readPath = isAbsoluteSourcePath(path) ? path : '$root/$path';
      String content;
      try {
        content = utf8.decode(
          File(readPath).readAsBytesSync(),
          allowMalformed: true,
        );
      } on FileSystemException {
        // Observation, not diagnosis: MISSING (vs unreadable) means
        // the compile saw a file the mapping cannot find — moved mid-
        // build, or behind a non-traversable parent — and the two need
        // different fixes, so the reason splits them.
        onSkip?.call(
          path,
          File(readPath).existsSync()
              ? 'unreadable'
              : 'missing on disk — moved during the build, or an '
                  'unreadable parent directory?',
        );
        continue;
      }
      if (dartSourceIsPart(content)) continue;
      uris.add('package:$packageName/$rel');
    }
    uris.sort();
    return uris;
  }

  static String _tryResolve(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  /// Packages excluded from [dependencyPackageLibrariesFromClosure]:
  /// `flutter` stays under the curated candidate list
  /// ([kIosInterfaceFreezeFlutterCandidates]) so only its stable
  /// barrels are frozen, and the rest are tooling/SDK-shim packages a
  /// patch has no business reaching.
  static const Set<String> kIosFreezeExcludedDependencyPackages = {
    'flutter',
    'flutter_test',
    'flutter_localizations',
    'flutter_web_plugins',
    'sky_engine',
  };

  /// Map the compile closure's source paths to the library URIs of the
  /// app's DEPENDENCY packages (path, git, and hosted), translating
  /// on-disk prefixes into `package:` URIs via the project's
  /// `.dart_tool/package_config.json`. Complements
  /// [appLibrariesFromClosure] (which covers only the main package) so
  /// a release freezes every package the app actually compiles: an
  /// unfrozen package library keeps no public dictionary in release
  /// builds, so code delivered later that merely IMPORTS it can
  /// resolve nothing through it. Same filters as the app mapping:
  /// dead files never appear (closure-driven), part files are
  /// excluded, unsafe URIs are skipped and reported via [onSkip].
  /// The main package ([packageName]) and
  /// [kIosFreezeExcludedDependencyPackages] are excluded. Returns an
  /// empty list when the package config is absent or unreadable — the
  /// freeze then simply keeps its previous (main-package + framework)
  /// scope rather than failing the build.
  static List<String> dependencyPackageLibrariesFromClosure({
    required Set<String> closurePaths,
    required String projectRoot,
    required String packageName,
    void Function(String path, String reason)? onSkip,
    bool? windowsPaths,
  }) {
    final windows = windowsPaths ?? Platform.isWindows;
    final configFile = File('$projectRoot/.dart_tool/package_config.json');
    if (!configFile.existsSync()) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(configFile.readAsStringSync());
    } on Object {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final packages = decoded['packages'];
    if (packages is! List) return const [];
    // Package name -> normalized absolute lib/ path prefix candidates
    // (literal + symlink-resolved).
    final prefixes = <String, Set<String>>{};
    // Relative rootUris resolve against the config file's directory
    // per the package_config spec.
    final configDirUri = Directory(
      '$projectRoot/.dart_tool',
    ).absolute.uri;
    for (final entry in packages) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final rootUri = entry['rootUri'];
      if (name is! String || rootUri is! String) continue;
      // The name is embedded verbatim into the spec's `package:` URIs
      // and their single-quoted YAML scalars, so enforce the same
      // charset [parsePubspecName] accepts for the app's own name. Pub
      // never produces a name outside it; only a hand-edited config
      // can, and a quote/newline there would corrupt (or inject into)
      // the emitted spec.
      if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(name)) {
        onSkip?.call(
          'package "${name.replaceAll(RegExp(r'[^A-Za-z0-9_\-. ]'), '?')}"',
          'unsupported characters in package name',
        );
        continue;
      }
      if (name == packageName ||
          kIosFreezeExcludedDependencyPackages.contains(name)) {
        continue;
      }
      final packageUri = entry['packageUri'];
      // Spec-legal empty packageUri means "import root == rootUri";
      // './' resolves to the base directory, whereas forcing '/' onto
      // an empty segment would be an ABSOLUTE-path reference that
      // resolves to the filesystem root — a '/' prefix would then
      // hijack every closure path into this package.
      var libSegment = packageUri is String ? packageUri : 'lib/';
      if (libSegment.isEmpty) libSegment = './';
      // Reject the INPUT class, not one bad output: a path-absolute or
      // scheme-carrying packageUri (spec-illegal; only relative values
      // are produced by pub) would resolve by DISCARDING the package
      // root entirely (RFC 3986 §5.3) and register a prefix from the
      // filesystem root — the fabricate-instead-of-degrade hijack.
      if (libSegment.startsWith('/') ||
          libSegment.startsWith(r'\') ||
          libSegment.contains(':')) {
        continue;
      }
      final Uri? parsedRoot = Uri.tryParse(
        rootUri.endsWith('/') ? rootUri : '$rootUri/',
      );
      if (parsedRoot == null) continue;
      if (parsedRoot.hasScheme && parsedRoot.scheme != 'file') continue;
      final Uri libUri;
      try {
        final rootResolved = configDirUri.resolveUri(parsedRoot);
        libUri = rootResolved.resolve(
          libSegment.endsWith('/') ? libSegment : '$libSegment/',
        );
        // CONTAINMENT: the lib prefix must sit inside the package root.
        // This closes the whole escape class at once — absolute inputs,
        // '..' traversal, and any future resolution trick — instead of
        // enumerating bad shapes (rounds 2-4 each found one).
        final rootPath = _normalizePath(
          rootResolved.toFilePath(windows: windows),
          windows: windowsPaths,
        );
        final libPath = libUri.toFilePath(windows: windows);
        if (!_normalizePath(libPath, windows: windowsPaths)
            .startsWith(rootPath)) {
          continue;
        }
        // The front-end may write resolved (symlink-free) paths into the
        // depfile (the same reason appLibrariesFromClosure carries a
        // _tryResolve fallback for the project root) — register BOTH the
        // literal prefix and the symlink-resolved one, or symlinked
        // layouts (macOS /tmp, monorepo path deps) silently drop every
        // file of the package from the freeze.
        // Defense-in-depth for any degenerate resolution: a root ('/')
        // prefix would match every absolute path.
        if (_normalizePath(libPath, windows: windowsPaths) == '/') {
          continue;
        }
        final candidates = prefixes.putIfAbsent(name, () => <String>{});
        candidates.add(_normalizePath(libPath, windows: windowsPaths));
        var resolved = _tryResolve(libPath);
        if (!resolved.endsWith('/')) resolved = '$resolved/';
        candidates.add(_normalizePath(resolved, windows: windowsPaths));
      } on Object {
        continue;
      }
    }
    if (prefixes.isEmpty) return const [];
    final safe = RegExp(r'^[A-Za-z0-9_\-./]+$');
    final uris = <String>{};
    for (final rawPath in closurePaths) {
      final path = _normalizePath(rawPath, windows: windowsPaths);
      if (!path.endsWith('.dart')) continue;
      String? matchedPackage;
      String? matchedPrefix;
      for (final packageEntry in prefixes.entries) {
        for (final prefix in packageEntry.value) {
          if (path.startsWith(prefix)) {
            matchedPackage = packageEntry.key;
            matchedPrefix = prefix;
            break;
          }
        }
        if (matchedPackage != null) break;
      }
      if (matchedPackage == null) continue;
      final rel = path.substring(matchedPrefix!.length);
      if (rel.split('/').any((seg) => seg.startsWith('.'))) continue;
      if (!safe.hasMatch(rel)) {
        onSkip?.call(path, 'unsupported characters in path');
        continue;
      }
      String content;
      try {
        // Read via the NORMALIZED path — same contract as
        // appLibrariesFromClosure: matching and reading must agree even
        // for windowsPaths-normalized inputs.
        content = utf8.decode(
          File(path).readAsBytesSync(),
          allowMalformed: true,
        );
      } on FileSystemException {
        onSkip?.call(
          path,
          File(path).existsSync()
              ? 'unreadable'
              : 'missing on disk — moved during the build, or an '
                  'unreadable parent directory?',
        );
        continue;
      }
      if (!dartSourceIsPart(content)) {
        uris.add('package:$matchedPackage/$rel');
      }
    }
    final sorted = uris.toList()..sort();
    return sorted;
  }

  /// The subset of [includeUris] whose `package:` URI maps to no
  /// source file in [closurePaths] (the patch compile's transitive
  /// closure) — each is a silent no-op downstream: the module build
  /// SELECTS from the compiled input and cannot add what was never
  /// compiled in, so a library unreachable from the patch entry's
  /// import chain must be reported here or the operator learns it
  /// only on device. Advisory and conservative: URIs that cannot be
  /// verified (non-`package:` scheme, malformed, absent/unreadable
  /// package config) are NOT reported — a false "matches nothing"
  /// would send the operator chasing a working include. A URI naming
  /// a package absent from the config IS reported: the compile that
  /// produced [closurePaths] resolved through that same config, so
  /// the package's libraries cannot be in the input. Never throws.
  static List<String> unmatchedPackageIncludeUris({
    required List<String> includeUris,
    required Set<String> closurePaths,
    required String projectRoot,
    bool? windowsPaths,
  }) {
    final windows = windowsPaths ?? Platform.isWindows;
    final packageUris = [
      for (final uri in includeUris)
        if (uri.startsWith('package:')) uri,
    ];
    if (packageUris.isEmpty) return const [];
    final configFile = File('$projectRoot/.dart_tool/package_config.json');
    if (!configFile.existsSync()) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(configFile.readAsStringSync());
    } on Object {
      return const [];
    }
    if (decoded is! Map<String, Object?>) return const [];
    final packages = decoded['packages'];
    if (packages is! List) return const [];
    final configDirUri = Directory('$projectRoot/.dart_tool').absolute.uri;
    // Package name -> lib/ directory path (trailing separator kept by
    // toFilePath on a directory URI). Resolution mirrors
    // [dependencyPackageLibrariesFromClosure] minus its emission
    // hardening: this map only answers a membership question, so a
    // degenerate config can at worst suppress a warning, never
    // corrupt an artifact.
    final libDirs = <String, String>{};
    for (final entry in packages) {
      if (entry is! Map) continue;
      final name = entry['name'];
      final rootUri = entry['rootUri'];
      if (name is! String || rootUri is! String) continue;
      final packageUri = entry['packageUri'];
      var libSegment = packageUri is String ? packageUri : 'lib/';
      if (libSegment.isEmpty) libSegment = './';
      final parsedRoot = Uri.tryParse(
        rootUri.endsWith('/') ? rootUri : '$rootUri/',
      );
      if (parsedRoot == null) continue;
      if (parsedRoot.hasScheme && parsedRoot.scheme != 'file') continue;
      try {
        final libUri = configDirUri.resolveUri(parsedRoot).resolve(
              libSegment.endsWith('/') ? libSegment : '$libSegment/',
            );
        libDirs[name] = libUri.toFilePath(windows: windows);
      } on Object {
        continue;
      }
    }
    final closure = {
      for (final p in closurePaths) _normalizePath(p, windows: windowsPaths),
    };
    // The front-end may write project-root-relative source paths into
    // the depfile, depending on version — [appLibrariesFromClosure]
    // carries a bare 'lib/' prefix for the same reason. Precompute the
    // root spellings (literal + symlink-resolved, trailing separator
    // kept) so each absolute candidate below can also be compared
    // relative to the project root; without them a relative-path
    // closure would report EVERY include as "matches no library" —
    // the one false positive the doc comment above rules out. On any
    // resolution failure the set stays empty: the absolute comparison
    // still runs, so a warning can at worst be kept, never invented.
    final rootPrefixes = <String>{};
    try {
      final rootPath = _normalizePath(
        Directory(projectRoot).absolute.uri.normalizePath().toFilePath(
              windows: windows,
            ),
        windows: windowsPaths,
      );
      final resolvedRoot = _normalizePath(
        _tryResolve(rootPath),
        windows: windowsPaths,
      );
      for (final root in {rootPath, resolvedRoot}) {
        rootPrefixes.add(root.endsWith('/') ? root : '$root/');
      }
    } on Object {
      // Keep the absolute-only comparison.
    }
    final unmatched = <String>[];
    for (final uri in packageUris) {
      final rest = uri.substring('package:'.length);
      final slash = rest.indexOf('/');
      // No package name or no library path — unverifiable, not
      // reportable as "matches nothing".
      if (slash <= 0 || slash == rest.length - 1) continue;
      final name = rest.substring(0, slash);
      final rel = rest.substring(slash + 1);
      final libDir = libDirs[name];
      if (libDir == null) {
        unmatched.add(uri);
        continue;
      }
      final literal = _normalizePath('$libDir$rel', windows: windowsPaths);
      // The front-end may write symlink-resolved paths into the
      // depfile — accept either spelling, like the freeze mapping.
      final resolved = _normalizePath(
        _tryResolve(literal),
        windows: windowsPaths,
      );
      final candidates = {literal, resolved};
      for (final prefix in rootPrefixes) {
        for (final absolute in [literal, resolved]) {
          if (absolute.startsWith(prefix)) {
            candidates.add(absolute.substring(prefix.length));
          }
        }
      }
      if (!candidates.any(closure.contains)) {
        unmatched.add(uri);
      }
    }
    return unmatched;
  }

  /// The subset of [kIosInterfaceFreezeFlutterCandidates] whose source
  /// file appears in the compile closure.
  static List<String> flutterLibrariesFromClosure(
    Set<String> closurePaths, {
    bool? windowsPaths,
  }) {
    // Materialized: the lazy iterable would re-normalize the whole
    // closure once per candidate below.
    final normalized =
        _normalizeClosure(closurePaths, windows: windowsPaths).toList();
    return [
      for (final candidate in kIosInterfaceFreezeFlutterCandidates)
        if (normalized.any(
          (p) => p.endsWith(
            '/flutter/lib/${candidate.split('/').last}',
          ),
        ))
          candidate,
    ];
  }

  /// Widget base classes marked extendable so a patch may declare new
  /// subclasses (new screens/widgets): the compiler then guards
  /// dispatch on these hierarchies so instances of classes registered
  /// after the build dispatch correctly. The caller decides inclusion
  /// (see [closureHasExtendableFramework]); [buildIosInterfaceFreezeYaml]
  /// itself defaults the section off.
  ///
  /// Deliberate v1 scope: patches may subclass these three bases only.
  /// InheritedWidget / RenderObjectWidget share the failure mode but
  /// sit on the hottest dispatch surfaces in the framework — guarding
  /// them costs every app on every build for a capability no patch
  /// uses yet. Grow this list from patch reality, like the callable
  /// list, and re-run the device validation when it grows. Kept
  /// minimal because each entry disables devirtualization for its
  /// whole hierarchy.
  ///
  /// Path assumption validated against Flutter 3.41.2 (real pre-pass
  /// closure, 2026-08-14). A future SDK that moves or splits
  /// framework.dart breaks the closure gate — re-verify on SDK layout
  /// changes; the gate-miss error names "SDK newer than fcp" as a
  /// candidate cause for exactly that case.
  static const String kIosExtendableFrameworkLibrary =
      'package:flutter/src/widgets/framework.dart';
  static const List<String> kIosExtendableFrameworkClasses = [
    'StatelessWidget',
    'StatefulWidget',
    'State',
  ];

  /// Build the interface-freeze specification for an iOS release build:
  /// the compiler keeps the listed libraries' public call shapes intact
  /// (no signature specialization) so code delivered later can call
  /// them reliably. Pure so tests can pin the exact document produced.
  static String buildIosInterfaceFreezeYaml({
    required List<String> flutterLibraries,
    required List<String> appLibraries,
    bool includeExtendable = false,
  }) {
    final buffer = StringBuffer()
      ..writeln('# Generated by fcp codepush release. Do not edit.')
      ..writeln('# Freezes public call shapes for OTA compatibility.')
      ..writeln('callable:');
    for (final lib in [
      ...kIosInterfaceFreezeDartLibraries,
      ...flutterLibraries,
      ...appLibraries,
    ]) {
      buffer.writeln("  - library: '$lib'");
    }
    if (includeExtendable) {
      // One scalar entry per class: the schema's battle-tested form
      // (the list form exists in the parser but is coverage-ignored
      // upstream).
      buffer.writeln('extendable:');
      for (final cls in kIosExtendableFrameworkClasses) {
        buffer
          ..writeln("  - library: '$kIosExtendableFrameworkLibrary'")
          ..writeln("    class: '$cls'");
      }
    }
    return buffer.toString();
  }

  /// Write the interface-freeze spec derived from [closurePaths] into
  /// [specDirPath], returning a record with the written spec path, the
  /// app and framework library counts, and whether the extendable
  /// section was emitted. Pulls together the gate
  /// ([closureHasExtendableFramework]), the library mapping, and the
  /// yaml emission so the whole closure→file chain is testable.
  /// Returns null (nothing written) when no app libraries map — the
  /// caller treats that as fatal. A filesystem failure writing the
  /// spec throws [FlutterCompileException] instead of returning null,
  /// so the two failure classes stay distinguishable.
  ///
  /// `extendable` is false when [allowExtendable] is false OR the
  /// framework library is not in the closure; the writer stays a
  /// flag-agnostic API, so deciding how loud each cause must be —
  /// including the un-chosen gate miss — is the caller's job.
  /// `specChange` is three-valued: `changed` only when every swept
  /// spec's name differs (the previous option string provably
  /// differed, so a missing report afterwards cannot be explained by
  /// compile reuse); `unchanged` when the single swept name matches;
  /// `unknown` otherwise — an empty directory (wiped build/, full
  /// clean, or a prior refusal's sweep) or an ambiguous multi-spec
  /// sweep proves nothing either way.
  ///
  /// [allowExtendable] defaults ON — it carries the user-facing
  /// `--extendable-widgets` opt-out — deliberately opposite to the pure
  /// builder's `includeExtendable` default: the builder emits nothing
  /// it was not explicitly asked for, while this writer applies the
  /// product default.
  ({
    String specPath,
    int appCount,
    int flutterCount,
    bool extendable,
    freeze_files.InterfaceSpecChange specChange,
  })? writeIosInterfaceFreezeSpec({
    required Set<String> closurePaths,
    required String projectRoot,
    required String packageName,
    required String specDirPath,
    bool allowExtendable = true,
    void Function(String path, String reason)? onSkip,
  }) {
    // Sweep BEFORE the mapping can refuse, so an aborted run leaves no
    // previous spec behind (its report was already deleted by the
    // command; the two artifacts must never describe different runs).
    final sweptSpecs = freeze_files.sweepInterfaceSpecs(specDirPath);
    final appLibraries = appLibrariesFromClosure(
      closurePaths: closurePaths,
      projectRoot: projectRoot,
      packageName: packageName,
      onSkip: onSkip,
    );
    if (appLibraries.isEmpty) return null;
    // Dependency packages join the freeze alongside the app's own
    // libraries: in release builds an unfrozen package library keeps
    // no public dictionary, so later-delivered code that imports it
    // resolves nothing through it. The app count reported below stays
    // main-package-only; dependency libraries ride in the same
    // callable section.
    final dependencyLibraries = dependencyPackageLibrariesFromClosure(
      closurePaths: closurePaths,
      projectRoot: projectRoot,
      packageName: packageName,
      onSkip: onSkip,
    );
    final flutterLibraries = flutterLibrariesFromClosure(closurePaths);
    final includeExtendable =
        allowExtendable && closureHasExtendableFramework(closurePaths);
    final yaml = buildIosInterfaceFreezeYaml(
      flutterLibraries: flutterLibraries,
      appLibraries: [...appLibraries, ...dependencyLibraries],
      includeExtendable: includeExtendable,
    );
    // Content-addressed name: the build fingerprint includes the
    // front-end option STRING, not the spec file's bytes, so a
    // same-path spec with changed contents would be silently ignored
    // by a cached kernel step. Hashing the content into the name makes
    // any spec change bust the cache; the sweep above already cleared
    // every stale sibling (hashed or the legacy fixed name).
    final specName = freeze_files.interfaceSpecFilenameFor(yaml);
    final specPath = '$specDirPath/$specName';
    // Three states, not two: `changed` requires evidence (every swept
    // name differs, so the previous option string — whichever it was —
    // differed); `unchanged` requires the single swept name to match;
    // everything else is `unknown` (an empty directory proves nothing:
    // rm -rf build/, a full clean, or a prior refusal's sweep; a
    // multi-spec sweep with one match is ambiguous). Downstream, only
    // `changed` supports an actionable missing-report warning.
    // (Heuristic even so: re-toggling an option back can land on an
    // older warm env-hash directory.)
    final freeze_files.InterfaceSpecChange specChange;
    if (sweptSpecs.isEmpty) {
      specChange = freeze_files.InterfaceSpecChange.unknown;
    } else if (!sweptSpecs.contains(specName)) {
      specChange = freeze_files.InterfaceSpecChange.changed;
    } else if (sweptSpecs.length == 1) {
      specChange = freeze_files.InterfaceSpecChange.unchanged;
    } else {
      specChange = freeze_files.InterfaceSpecChange.unknown;
    }
    try {
      File(specPath).writeAsStringSync(yaml);
    } on FileSystemException catch (e) {
      // A disk/permission problem must not masquerade as the caller's
      // "no app libraries mapped" null. The message travels on the
      // typed exception; the CALLER logs it after failing its progress
      // line so the guidance prints under the failure marker like
      // every other error here (the runner's handler prints nothing).
      final reason = e.osError?.message ?? e.message;
      throw FlutterCompileException(
        'Could not write $specPath ($reason). Check permissions and '
        'free space on the build directory.',
      );
    }
    // Breadcrumbs AFTER the write, so a failing verbose transcript
    // never claims a spec state — or a from-scratch compile — for a
    // file that was never created.
    switch (specChange) {
      case freeze_files.InterfaceSpecChange.unknown when sweptSpecs.isEmpty:
        _logger.detail(
          'No previous interface spec in the build directory; after a '
          'full clean this release compiles from scratch.',
        );
      case freeze_files.InterfaceSpecChange.unknown:
        _logger.detail(
          'Multiple stale interface specs were swept; whether the '
          'compile can be reused is unknown.',
        );
      case freeze_files.InterfaceSpecChange.changed:
        // A changed option string is a new build environment: the next
        // build compiles from scratch in a fresh directory. Deliberate
        // (the recompile is the point), but it should not surprise
        // silently — flutter clean reclaims the old directories.
        _logger.detail(
          "Interface spec changed (the app's library set or guarding "
          'options differ from the previous build); this release will '
          'compile from scratch in a fresh build directory.',
        );
      case freeze_files.InterfaceSpecChange.unchanged:
        break;
    }
    final omittedReason =
        allowExtendable ? 'framework library not in the compile' : 'disabled';
    _logger.detail(
      includeExtendable
          ? 'Interface spec: widget base classes marked extendable.'
          : 'Interface spec: extendable section omitted ($omittedReason).',
    );
    return (
      specPath: specPath,
      appCount: appLibraries.length,
      flutterCount: flutterLibraries.length,
      extendable: includeExtendable,
      specChange: specChange,
    );
  }

  /// Whether the compile closure contains the framework library whose
  /// widget base classes we mark extendable — derived from
  /// [kIosExtendableFrameworkLibrary] so the two can never drift. The
  /// prefix assumption is pinned by the unit tests; the assert below is
  /// debug-only and compiled out of the shipped CLI.
  static bool closureHasExtendableFramework(
    Set<String> closurePaths, {
    bool? windowsPaths,
  }) {
    assert(
      kIosExtendableFrameworkLibrary.startsWith('package:flutter/'),
      'closureHasExtendableFramework assumes a package:flutter library',
    );
    final suffix = kIosExtendableFrameworkLibrary.replaceFirst(
      'package:flutter/',
      '/flutter/lib/',
    );
    return _normalizeClosure(closurePaths, windows: windowsPaths)
        .any((p) => p.endsWith(suffix));
  }

  /// Return [extraArgs] with `--extra-front-end-options` carrying the
  /// interface-freeze flags for an iOS release build.
  ///
  /// [freezeSpecPath] is the yaml written by
  /// [buildIosInterfaceFreezeYaml]; [reportPath], when given, asks the
  /// compiler to also write a machine-readable report of what was
  /// frozen (load-bearing: the release archive copies it as the
  /// compiler's own evidence and records it in the archive manifest —
  /// see CodePushArchiveService). Both paths must
  /// not contain commas: the surrounding tooling joins and re-splits
  /// this option list on commas, so a comma in a path silently corrupts
  /// every option after it. Callers must reject such paths first.
  ///
  /// Same merge semantics as [withIosReleaseGenSnapshotOptions]: append
  /// when absent, merge into an existing occurrence otherwise.
  static List<String> withIosReleaseFrontEndOptions(
    List<String> extraArgs, {
    required String freezeSpecPath,
    String? reportPath,
  }) {
    const prefix = '--extra-front-end-options=';
    final added = [
      '--dynamic-interface=$freezeSpecPath',
      if (reportPath != null) '--dump-detailed-dynamic-interface=$reportPath',
    ];
    final merged = [...extraArgs];
    final index = merged.indexWhere((arg) => arg.startsWith(prefix));
    if (index < 0) {
      return merged..add('$prefix${added.join(',')}');
    }
    final existing = merged[index].substring(prefix.length);
    final options = existing.split(',').where((o) => o.isNotEmpty).toList();
    for (final option in added) {
      // Dedupe by option NAME, not exact string: a user-supplied
      // `--dynamic-interface=<their path>` wins — appending a second one
      // would silently override theirs (last occurrence wins in the
      // front-end), taking away the only escape hatch. If a CLI path
      // ever routes a user-supplied value through here, the command's
      // attestation (writtenInterfaceSpec) must be cleared in lockstep:
      // it assumes fcp's own spec is the one the build consumed.
      // Unreachable today — extraBuildArgs carries only --dart-define.
      final name = option.substring(0, option.indexOf('=') + 1);
      if (!options.any((o) => o.startsWith(name))) {
        options.add(option);
      }
    }
    merged[index] = '$prefix${options.join(',')}';
    return merged;
  }

  /// Filename of the front end's detailed interface report (canonical
  /// value in interface_freeze_constants.dart; aliased here for the
  /// command's path composition).
  static const String kInterfaceReportFilename =
      freeze_files.kInterfaceReportFilename;

  /// Instance wrapper over [frontendSupportsDynamicInterface] so
  /// command-level tests can stub the probe.
  bool frontendSupportsFreeze(String flutterRoot) =>
      frontendSupportsDynamicInterface(flutterRoot);

  /// Whether the SDK's front-end snapshot recognises the
  /// `--dynamic-interface` option, probed by scanning the snapshot for
  /// the option name (AOT snapshots embed their option strings).
  /// Returns false for SDKs that predate the option, where passing it
  /// would fail the build with an opaque option error.
  static bool frontendSupportsDynamicInterface(String flutterRoot) {
    final snapshot = File(
      '$flutterRoot/bin/cache/dart-sdk/bin/snapshots/'
      'frontend_server_aot.dart.snapshot',
    );
    if (!snapshot.existsSync()) return false;
    final needle = 'dynamic-interface'.codeUnits;
    final bytes = snapshot.readAsBytesSync();
    outer:
    for (var i = 0; i <= bytes.length - needle.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  /// Whether `.dart_tool/package_config.json` under [projectRoot] is
  /// missing or older than the pubspec, i.e. `pub get` is needed before
  /// a front-end compile can resolve packages.
  static bool packageConfigStale(String projectRoot) {
    final config = File('$projectRoot/.dart_tool/package_config.json');
    if (!config.existsSync()) {
      // No pubspec → nothing to fetch; treat as not stale.
      return File('$projectRoot/pubspec.yaml').existsSync();
    }
    final pubspec = File('$projectRoot/pubspec.yaml');
    if (!pubspec.existsSync()) return false;
    return pubspec.lastModifiedSync().isAfter(config.lastModifiedSync());
  }

  /// Discover the app's compile closure by running a fast front-end
  /// compile of [targetPath] with a depfile, without whole-program
  /// optimization. Returns the set of source paths in the closure, or
  /// null on failure (with diagnostics logged). Used to generate the
  /// iOS interface freeze from what the build actually contains.
  ///
  /// Scope note: [projectRootOverride] covers the PRE-FLIGHT gates
  /// only (pub-get staleness, l10n detection). The compile itself —
  /// the relative [targetPath], the package config, and the spawned
  /// process — resolves against the current directory, which in
  /// production IS the project root. A test that points the override
  /// at a fixture root must also chdir there.
  Future<Set<String>?> discoverCompileClosure({
    required String targetPath,
    required String workDirPath,
    String? flutterRootOverride,
    String? projectRootOverride,
    ProcessResult Function(String executable, List<String> args)? runProcess,
  }) async {
    final depfilePath = '$workDirPath/closure.d';
    final dillPath = '$workDirPath/closure.dill';
    final flutterRoot = flutterRootOverride ?? _findActiveFlutterRoot();
    if (flutterRoot == null) {
      _logger.err('Could not locate the active Flutter SDK root.');
      return null;
    }
    // `flutter build` runs an implicit `pub get` (which also writes the
    // synthetic localization package into package_config.json); this
    // pre-pass runs before it, so it must do the same or a fresh clone
    // and gen_l10n apps fail here despite being buildable. Gated on
    // staleness so an up-to-date tree never touches the network.
    final projectRoot = projectRootOverride ?? Directory.current.path;
    if (packageConfigStale(projectRoot)) {
      final flutterBin = runProcess != null ? 'flutter' : findFlutterBin();
      if (flutterBin != null) {
        try {
          final pubGet = (runProcess ?? Process.runSync)(
            flutterBin,
            ['pub', 'get'],
          );
          if (pubGet.exitCode != 0) {
            _logger.err(
              'flutter pub get failed before the release pre-pass:\n'
              '${pubGet.stderr}',
            );
            return null;
          }
        } on ProcessException catch (e) {
          _logger.err('flutter pub get could not start: $e');
          return null;
        }
      }
    }
    // Localization sources (`package:flutter_gen/gen_l10n/...`) are
    // emitted by codegen, not by pub get; `flutter build` runs it
    // implicitly, so the pre-pass must too or l10n apps fail here.
    if (File('$projectRoot/l10n.yaml').existsSync()) {
      final flutterBin = runProcess != null ? 'flutter' : findFlutterBin();
      if (flutterBin != null) {
        try {
          final genL10n = (runProcess ?? Process.runSync)(
            flutterBin,
            ['gen-l10n'],
          );
          if (genL10n.exitCode != 0) {
            _logger.err(
              'flutter gen-l10n failed before the release pre-pass:\n'
              '${genL10n.stderr}',
            );
            return null;
          }
        } on ProcessException catch (e) {
          _logger.err('flutter gen-l10n could not start: $e');
          return null;
        }
      }
    }
    final dartAotRuntime = '$flutterRoot/bin/cache/dart-sdk/bin/dartaotruntime';
    final frontendServer = '$flutterRoot/bin/cache/dart-sdk/bin/snapshots/'
        'frontend_server_aot.dart.snapshot';
    final sdkRoot = '$flutterRoot/bin/cache/artifacts/engine/common/'
        'flutter_patched_sdk_product/';
    if (runProcess == null &&
        (!File(dartAotRuntime).existsSync() ||
            !File(frontendServer).existsSync() ||
            !Directory(sdkRoot).existsSync())) {
      _logger.err(
        'The Flutter SDK cache is missing front-end artifacts. '
        'Run "flutter precache --ios" and retry; if that does not '
        'help, your Flutter SDK may be too old to ship '
        'frontend_server_aot.dart.snapshot — upgrade Flutter.',
      );
      return null;
    }
    final args = <String>[
      frontendServer,
      ...patchKernelCompilerArgs(
        sdkRoot: sdkRoot,
        packagesPath: '.dart_tool/package_config.json',
        outputDillPath: dillPath,
        targetPath: targetPath,
      ),
      '--depfile',
      depfilePath,
    ];
    final ProcessResult result;
    try {
      result = (runProcess ?? Process.runSync)(dartAotRuntime, args);
    } on ProcessException catch (e) {
      _logger.err('Closure discovery compile could not start: $e');
      return null;
    }
    final depfile = File(depfilePath);
    try {
      if (result.exitCode != 0 || !depfile.existsSync()) {
        _logger.err(
          'Closure discovery compile failed '
          '(exit ${result.exitCode}).\n${result.stderr}',
        );
        return null;
      }
      return parseDepfileSources(depfile.readAsStringSync());
    } finally {
      // Discovery scratch files must not linger next to shipped
      // artifacts in build/codepush/.
      for (final scratch in [depfile, File(dillPath)]) {
        if (scratch.existsSync()) scratch.deleteSync();
      }
    }
  }

  /// Compile the iOS patch entry into its own kernel with the Flutter
  /// front-end, using release defines but no whole-program (`--aot`)
  /// optimization.
  ///
  /// The kernel that `flutter build ios --release` produces is
  /// whole-program optimized: call sites and signatures in it are
  /// specialized against the one program being built. A patch payload
  /// compiled from that kernel can carry calls whose shape no longer
  /// matches the app being patched, which fails at run time. The patch
  /// pipeline therefore compiles a dedicated kernel in which every
  /// external reference keeps its public shape.
  ///
  /// [dartDefines] should carry the same `--dart-define` set the
  /// baseline release was built with: const environment values are
  /// baked in at compile time, so a mismatch changes behavior of the
  /// patched code relative to the deployed app.
  ///
  /// [runProcess] is a test seam; production callers omit it.
  Future<BuildStepResult> compilePatchKernel({
    required String targetPath,
    required String outputDillPath,
    List<String> dartDefines = const [],
    String? flutterRootOverride,
    String? depfilePath,
    ProcessResult Function(String executable, List<String> args)? runProcess,
  }) async {
    final flutterRoot = flutterRootOverride ?? _findActiveFlutterRoot();
    if (flutterRoot == null) {
      return const BuildStepResult(
        success: false,
        message: 'Could not locate the active Flutter SDK root.',
      );
    }
    final dartAotRuntime = '$flutterRoot/bin/cache/dart-sdk/bin/dartaotruntime';
    final frontendServer = '$flutterRoot/bin/cache/dart-sdk/bin/snapshots/'
        'frontend_server_aot.dart.snapshot';
    final sdkRoot = '$flutterRoot/bin/cache/artifacts/engine/common/'
        'flutter_patched_sdk_product/';
    if (!File(dartAotRuntime).existsSync() ||
        !File(frontendServer).existsSync() ||
        !Directory(sdkRoot).existsSync()) {
      return const BuildStepResult(
        success: false,
        message: 'The Flutter SDK cache is missing front-end artifacts. '
            'Run "flutter precache --ios" and retry; if that does not '
            'help, your Flutter SDK may be too old to ship '
            'frontend_server_aot.dart.snapshot — upgrade Flutter.',
      );
    }

    final outputFile = File(outputDillPath);
    outputFile.parent.createSync(recursive: true);
    // A stale kernel from an earlier run must never satisfy the
    // output existence check below.
    if (outputFile.existsSync()) {
      outputFile.deleteSync();
    }
    // Same rule for the depfile: a stale closure from an earlier run
    // must never answer this run's include-URI verification.
    if (depfilePath != null) {
      final depFile = File(depfilePath);
      if (depFile.existsSync()) {
        try {
          depFile.deleteSync();
        } on FileSystemException {
          // Best-effort: the depfile is advisory-only downstream.
        }
      }
    }

    final args = <String>[
      frontendServer,
      ...patchKernelCompilerArgs(
        sdkRoot: sdkRoot,
        packagesPath: '.dart_tool/package_config.json',
        outputDillPath: outputDillPath,
        targetPath: targetPath,
        dartDefines: dartDefines,
        depfilePath: depfilePath,
      ),
    ];
    final result = (runProcess ?? Process.runSync)(dartAotRuntime, args);
    final ok = result.exitCode == 0 && outputFile.existsSync();
    return BuildStepResult(
      success: ok,
      message: ok ? null : 'Patch kernel compile failed.',
      command: [dartAotRuntime, ...args],
      exitCode: result.exitCode,
      stdout: result.stdout as String?,
      stderr: result.stderr as String?,
    );
  }

  /// Produce the Android/desktop patch payload from [kernelPath] by
  /// invoking the private build tool. Non-iOS only.
  Future<BuildStepResult> snapshotFromKernel({
    required String kernelPath,
    required String platform,
    required String target,
    required String flutterVersion,
    required String outputPath,
    required CodePushArtifactManager artifactManager,
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      return const BuildStepResult(
        success: false,
        message: 'Build tool not available. '
            'Run "fcp codepush setup" first to download it.',
      );
    }
    final outputFile = File(outputPath);
    outputFile.parent.createSync(recursive: true);

    final args = <String>[
      'snapshot',
      '--platform',
      platform,
      '--target',
      target,
      '--flutter-version',
      flutterVersion,
      '--dill',
      kernelPath,
      '--output',
      outputPath,
    ];
    final result = Process.runSync(tool, args);
    return BuildStepResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0 ? null : 'Patch build failed.',
      command: [tool, ...args],
      exitCode: result.exitCode,
      stdout: result.stdout as String?,
      stderr: result.stderr as String?,
    );
  }

  /// Prepares the environment for an Android code-push build.
  ///
  /// Delegates to the build tool, which sets up everything `flutter
  /// build` needs to produce an app that packages the code-push engine,
  /// and reports the environment variables to put on the build process
  /// plus the engine library's SHA-256 for post-build verification.
  ///
  /// Returns null on any failure. Callers must treat null as fatal for
  /// the build — falling back silently would produce an app that cannot
  /// load patches.
  Future<AndroidEnginePrep?> prepareAndroidEngineBuild({
    required String flutterVersion,
    required CodePushArtifactManager artifactManager,
    String? flutterRootOverride,
  }) async {
    final engineReady = await artifactManager.ensureAndroidEngine(
      flutterVersion: flutterVersion,
    );
    if (!engineReady) {
      _logger.err(
        'Android engine artifacts are not available for Flutter '
        '$flutterVersion. Run "fcp codepush setup --platform android '
        '--flutter-version $flutterVersion" first.',
      );
      return null;
    }
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      _logger.err(
        'Build tool not available. Run "fcp codepush setup" first.',
      );
      return null;
    }
    final flutterRoot = flutterRootOverride ?? _findActiveFlutterRoot();
    if (flutterRoot == null) {
      _logger.err('Could not locate the active Flutter SDK root.');
      return null;
    }

    final tempDir = Directory.systemTemp.createTempSync('fcp_engine_prep_');
    final outFile = File('${tempDir.path}/prep.json');
    try {
      final result = Process.runSync(tool, [
        'engine-prepare',
        '--flutter-version',
        flutterVersion,
        '--sdk-root',
        flutterRoot,
        '--output',
        outFile.path,
      ]);
      if (result.exitCode != 0) {
        final stderrText = (result.stderr as String?)?.trim() ?? '';
        // Substring is coupled to the args CommandRunner's
        // unknown-command wording in the tool; if it drifts, this
        // degrades to the generic message below (still a safe failure).
        if (stderrText.contains('Could not find a command named')) {
          // Older tool binary without this step (see the fcp-tool
          // protocol note: new subcommands need a feature probe).
          _logger.err(
            'The code push build tool is out of date. '
            'Run "fcp codepush setup --force" and retry.',
          );
        } else {
          _logger.err('Android build preparation failed.');
          if (stderrText.isNotEmpty) _logger.err(stderrText);
        }
        return null;
      }
      final decoded = jsonDecode(outFile.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        _logger.err('Android build preparation returned an invalid result.');
        return null;
      }
      final envRaw = decoded['env'];
      final sha = decoded['engine_sha256'];
      if (envRaw is! Map<String, dynamic> || sha is! String || sha.isEmpty) {
        _logger.err('Android build preparation returned an invalid result.');
        return null;
      }
      return AndroidEnginePrep(
        environment: envRaw.map((k, v) => MapEntry(k, v.toString())),
        engineSha256: sha,
      );
    } on FormatException {
      _logger.err('Android build preparation returned an invalid result.');
      return null;
    } on Exception catch (e) {
      // A tool binary that's present but not executable / wrong arch /
      // on a noexec mount throws ProcessException; treat every failure
      // here as "tool unusable" with the actionable fix, never a crash.
      _logger.err(
        'Android build preparation failed: $e\n'
        'Run "fcp codepush setup --force" and retry.',
      );
      return null;
    } finally {
      try {
        tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Best-effort temp cleanup.
      }
    }
  }

  /// Whether [archivePath] (an APK or AAB) contains an arm64 engine
  /// library whose SHA-256 equals [expectedSha256].
  static bool androidArchiveContainsEngine({
    required String archivePath,
    required String expectedSha256,
  }) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(File(archivePath).readAsBytesSync());
    } on Exception {
      return false;
    }
    for (final entry in archive.files) {
      // APK: lib/arm64-v8a/libflutter.so; AAB: base/lib/arm64-v8a/...
      if (entry.isFile && entry.name.endsWith('lib/arm64-v8a/libflutter.so')) {
        final sha = sha256.convert(entry.content as List<int>).toString();
        return sha == expectedSha256;
      }
    }
    return false;
  }

  /// Locates the artifact a just-finished Android release build wrote,
  /// preferring the canonical output paths and falling back to the
  /// newest matching file (flavored builds use different names).
  String? _findBuiltAndroidArtifact(String platform) {
    if (platform == 'appbundle') {
      const canonical = 'build/app/outputs/bundle/release/app-release.aab';
      if (File(canonical).existsSync()) return canonical;
      return _newestFileWithSuffix('build/app/outputs/bundle', '.aab');
    }
    const canonical = 'build/app/outputs/flutter-apk/app-release.apk';
    if (File(canonical).existsSync()) return canonical;
    return _newestFileWithSuffix('build/app/outputs/flutter-apk', '.apk');
  }

  static String? _newestFileWithSuffix(String dir, String suffix) {
    final d = Directory(dir);
    if (!d.existsSync()) return null;
    File? newest;
    var newestTime = DateTime.fromMillisecondsSinceEpoch(0);
    for (final entity in d.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith(suffix)) {
        final t = entity.lastModifiedSync();
        if (t.isAfter(newestTime)) {
          newest = entity;
          newestTime = t;
        }
      }
    }
    return newest?.path;
  }

  /// Run the finalize step of the build tool.
  ///
  /// Returns a [BuildStepResult]; on failure, callers should pass
  /// [BuildStepResult.message] to `progress.fail(...)` and then log
  /// [BuildStepResult.formatDiagnostics] via `_logger.err(...)`.
  Future<BuildStepResult> finalizeBuild({
    required String buildPlatform,
    String? flutterVersion,
    required CodePushArtifactManager artifactManager,
  }) async {
    if (buildPlatform == 'ios') {
      // iOS must be built against the fcp-patched SDK up front.
      // Swapping only Flutter.framework after build leaves App.framework
      // compiled against stock dart:ui/platform dill and crashes before main().
      return const BuildStepResult(
        success: true,
        message: 'iOS build already finalized during prepare.',
      );
    }

    final isAndroid = buildPlatform == 'apk' ||
        buildPlatform == 'appbundle' ||
        buildPlatform == 'android';
    if (isAndroid && _androidEngineVerified) {
      // The engine was packaged during the build itself and the built
      // artifact verified; the post-build swap has nothing left to do.
      return const BuildStepResult(
        success: true,
        message: 'Android engine installed and verified during build.',
      );
    }

    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      return const BuildStepResult(
        success: false,
        message: 'Build tool not available. '
            'Run "fcp codepush setup" first to download it.',
      );
    }
    final args = <String>[
      'finalize',
      buildPlatform,
      if (flutterVersion != null) ...['--flutter-version', flutterVersion],
    ];
    final result = Process.runSync(tool, args);
    return BuildStepResult(
      success: result.exitCode == 0,
      message: result.exitCode == 0 ? null : 'Build finalization failed.',
      command: [tool, ...args],
      exitCode: result.exitCode,
      stdout: result.stdout as String?,
      stderr: result.stderr as String?,
    );
  }

  /// Produce a binary diff between [baseline] and [updated], using the
  /// build tool. Returns the raw patch bytes or null on failure.
  Future<Uint8List?> diffBytes({
    required Uint8List baseline,
    required Uint8List updated,
    required CodePushArtifactManager artifactManager,
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) return null;

    final tempDir = Directory.systemTemp.createTempSync('fcp_diff_');
    try {
      final baselineFile = File('${tempDir.path}/baseline.bin')
        ..writeAsBytesSync(baseline);
      final updatedFile = File('${tempDir.path}/updated.bin')
        ..writeAsBytesSync(updated);
      final outFile = '${tempDir.path}/patch.bin';
      final result = Process.runSync(tool, [
        'diff',
        baselineFile.path,
        updatedFile.path,
        '-o',
        outFile,
      ]);
      if (result.exitCode != 0) {
        _logger.err('Binary diff failed: ${result.stderr}');
        return null;
      }
      return Uint8List.fromList(File(outFile).readAsBytesSync());
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  }

  /// Wrap [payload] in the runtime container format and write it to
  /// [outputPath]. Delegates to the build tool.
  Future<bool> packagePayload({
    required Uint8List payload,
    required String outputPath,
    required CodePushArtifactManager artifactManager,
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) return false;

    final tempDir = Directory.systemTemp.createTempSync('fcp_pkg_');
    try {
      final payloadFile = File('${tempDir.path}/payload.bin')
        ..writeAsBytesSync(payload);
      final result = Process.runSync(tool, [
        'package',
        '--payload',
        payloadFile.path,
        '--output',
        outputPath,
      ]);
      if (result.exitCode != 0) {
        _logger.err('Packaging failed: ${result.stderr}');
        return false;
      }
      return true;
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  }
}
