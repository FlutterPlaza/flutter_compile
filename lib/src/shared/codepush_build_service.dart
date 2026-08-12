import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

import 'codepush_artifact_manager.dart';
import 'codepush_client.dart';

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
  /// null if `flutter` is not on PATH, the subprocess fails, or the output
  /// can't be parsed.
  Future<String?> detectFlutterVersion() async {
    final flutterBin = findFlutterBin();
    if (flutterBin == null) return null;
    try {
      final result = await Process.run(flutterBin, ['--version']);
      if (result.exitCode != 0) return null;
      return parseFlutterVersionOutput(result.stdout as String);
    } catch (_) {
      return null;
    }
  }

  /// Resolve the Flutter SDK version to use for code push build steps.
  ///
  /// Precedence:
  ///   1. [explicit] — typically from a `--flutter-version` CLI flag.
  ///   2. `flutter --version` output ([detectFlutterVersion]).
  ///   3. `codepush_engine_flutter_version` in `~/.flutter_compilerc`
  ///      ([CodePushClient.getStoredEngineFlutterVersion]).
  ///
  /// Returns null only when all three sources yield an empty/missing value.
  /// Callers should treat null as a user-facing error and tell the user to
  /// pass `--flutter-version` explicitly or run `fcp codepush setup`.
  Future<String?> resolveFlutterVersion({String? explicit}) async {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final detected = await detectFlutterVersion();
    if (detected != null && detected.isNotEmpty) return detected;
    final stored = await CodePushClient.getStoredEngineFlutterVersion();
    if (stored != null && stored.isNotEmpty) return stored;
    return null;
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

  /// Whether a flagless release must demand an explicit `--platform`:
  /// no explicit flag, nothing built this run, and the project is
  /// dual-platform (both `android/` and `ios/` exist). Directory
  /// detection probes `android/` first, so an intended iOS release
  /// would otherwise silently route into the Android branch — and a
  /// release creates a server record, which deserves an explicit
  /// choice.
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
  String? findIosBaselineAppBinaryPath() {
    const candidates = [
      'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App',
      'build/ios/archive/Runner.xcarchive/Products/Applications/'
          'Runner.app/Frameworks/App.framework/App',
    ];
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
  String? findAndroidBaselineLibPath() {
    const abis = ['arm64-v8a', 'armeabi-v7a'];
    const strippedRoot = 'build/app/intermediates/stripped_native_libs/release';
    // Known layouts first: AGP 8 inserts the strip task name into the
    // path; older AGP wrote directly under out/.
    for (final abi in abis) {
      for (final path in [
        '$strippedRoot/stripReleaseDebugSymbols/out/lib/$abi/libapp.so',
        '$strippedRoot/out/lib/$abi/libapp.so',
      ]) {
        if (File(path).existsSync()) return path;
      }
    }
    // Fallback: scan the stripped tree so a future AGP layout change
    // degrades to a search instead of a miss.
    final root = Directory(strippedRoot);
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
