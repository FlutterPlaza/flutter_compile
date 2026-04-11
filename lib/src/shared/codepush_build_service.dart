import 'dart:io';
import 'dart:typed_data';

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

/// Build service for code push operations.
///
/// Only high-level, non-proprietary glue lives here:
///   - locate the Flutter / Dart tools on PATH
///   - run `flutter build`
///   - compute SHA-256 hashes and sign payloads with RSA
///   - thin Process wrappers around the private `fcp-tool` binary
class CodePushBuildService {
  CodePushBuildService({required Logger logger}) : _logger = logger;

  final Logger _logger;

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
  Future<bool> buildRelease({
    required String platform,
    List<String> extraArgs = const [],
  }) async {
    final flutter = findFlutterBin();
    if (flutter == null) {
      _logger.err('Flutter not found on PATH.');
      return false;
    }

    final args = ['build', platform, '--release', ...extraArgs];
    _logger.detail('Running: flutter ${args.join(' ')}');

    final process = await Process.start(
      flutter,
      args,
      mode: ProcessStartMode.inheritStdio,
    );
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      _logger.err('Flutter build failed with exit code $exitCode');
      return false;
    }

    return true;
  }

  /// Find the code-push payload path for the given platform.
  ///
  /// Platform-specific output:
  ///
  ///   * **iOS**: the Dart **kernel** file (`.dart_tool/flutter_build/`
  ///     `<hash>/app.dill`). iOS patches are bytecode-interpreted by
  ///     the custom code-push engine, NOT loaded as native Mach-O —
  ///     Apple's code-signing rules forbid loading unsigned native
  ///     code at runtime. The AOT Mach-O at
  ///     `Runner.app/Frameworks/App.framework/App` is the *baseline*
  ///     (the initial app binary); it is not a valid patch payload
  ///     and will crash the VM with `SIGABRT` inside
  ///     `DN_Internal_loadDynamicModule` if passed to the engine's
  ///     dynamic module loader. Flutter writes the kernel file to a
  ///     content-hashed subdirectory under
  ///     `.dart_tool/flutter_build/`; when multiple subdirectories
  ///     exist (debug / profile / release), we return the most
  ///     recently modified `app.dill`.
  ///
  ///   * **Android / Linux / macOS / Windows**: the ELF AOT snapshot
  ///     (`libapp.so` / `app.so` / `App`). These platforms load the
  ///     AOT blob as a native shared library.
  String? findSnapshotPath(String platform) {
    // iOS: locate the kernel file under .dart_tool/flutter_build/.
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

    // Other platforms: ELF AOT snapshot candidates.
    final Map<String, List<String>> platformPaths = {
      'apk': [
        'build/app/intermediates/flutter/release/app.so',
        'build/app/intermediates/stripped_native_libs/release/out/lib/arm64-v8a/libapp.so',
        'build/app/intermediates/stripped_native_libs/release/out/lib/armeabi-v7a/libapp.so',
        'build/app/intermediates/flutter/release/arm64-v8a/app.so',
        'build/app/intermediates/flutter/release/armeabi-v7a/app.so',
        'build/app/outputs/flutter-apk/app-release.apk',
      ],
      'appbundle': [
        'build/app/intermediates/flutter/release/app.so',
      ],
      'linux': [
        'build/linux/x64/release/bundle/lib/libapp.so',
        'build/linux/arm64/release/bundle/lib/libapp.so',
      ],
      'macos': [
        'build/macos/Build/Products/Release/Runner.app/Contents/Frameworks/App.framework/App',
      ],
      'windows': [
        'build/windows/x64/runner/Release/app.so',
      ],
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

  /// Validates a payload's magic bytes against the expected format
  /// for [platform], returning `null` if the format is correct or a
  /// human-readable error message if it isn't.
  ///
  /// Expected formats:
  ///
  ///   * **iOS**: Dart kernel. Magic bytes: `90 AB CD EF`.
  ///   * **Other platforms**: ELF. Magic bytes: `7F 45 4C 46`.
  ///
  /// This is a fast-fail guard before calling `fcp-tool package` —
  /// it catches the wrong-format payload at upload time instead of
  /// at device-load time, where a Mach-O passed to the Dart VM's
  /// `loadDynamicModule` aborts the process with a `SIGABRT` that
  /// users can't recover from without uninstalling the app.
  static String? validatePayloadMagic(
    List<int> payload,
    String platform,
  ) {
    if (payload.length < 4) {
      return 'Payload is too small to contain a valid magic number '
          '(got ${payload.length} bytes, expected at least 4).';
    }
    String hex4() => payload
        .take(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');

    if (platform == 'ios') {
      final isKernel = payload[0] == 0x90 &&
          payload[1] == 0xAB &&
          payload[2] == 0xCD &&
          payload[3] == 0xEF;
      if (isKernel) return null;

      // Diagnose the two most likely wrong-format cases.
      final isMachO = (payload[0] == 0xFE &&
              payload[1] == 0xED &&
              payload[2] == 0xFA &&
              payload[3] == 0xCF) ||
          (payload[0] == 0xCF &&
              payload[1] == 0xFA &&
              payload[2] == 0xED &&
              payload[3] == 0xFE);
      if (isMachO) {
        return 'iOS payload is Mach-O (magic ${hex4()}), not a Dart '
            'kernel file. iOS patches must be kernel (.dill) — the '
            'custom code-push engine interprets bytecode because '
            'Apple code-signing forbids loading unsigned native code '
            'at runtime. This usually means `.dart_tool/flutter_build/'
            '<hash>/app.dill` could not be found and the build service '
            'fell back to App.framework/App.';
      }
      final isELF = payload[0] == 0x7F &&
          payload[1] == 0x45 &&
          payload[2] == 0x4C &&
          payload[3] == 0x46;
      if (isELF) {
        return 'iOS payload is ELF (magic ${hex4()}), not a Dart '
            'kernel file. Did you accidentally build for Android and '
            'upload with --platform ios?';
      }
      return 'iOS payload has unknown magic bytes ${hex4()} (expected '
          '90 AB CD EF for Dart kernel).';
    }

    // Non-iOS: expect ELF.
    final isELF = payload[0] == 0x7F &&
        payload[1] == 0x45 &&
        payload[2] == 0x4C &&
        payload[3] == 0x46;
    if (isELF) return null;
    return '$platform payload is not ELF (magic ${hex4()}, expected '
        '7F 45 4C 46).';
  }

  /// Sign data with RSA-SHA256 using a PEM private key file.
  Future<Uint8List?> signPayload(Uint8List data, String privateKeyPath) async {
    final keyFile = File(privateKeyPath);
    if (!keyFile.existsSync()) {
      _logger.err('Signing key not found: $privateKeyPath');
      return null;
    }
    final tempDir = Directory.systemTemp.createTempSync('fcp_sign_');
    try {
      final dataFile = File('${tempDir.path}/payload.bin');
      dataFile.writeAsBytesSync(data);
      final sigFile = '${tempDir.path}/payload.sig';

      final result = Process.runSync('openssl', [
        'dgst',
        '-sha256',
        '-sign',
        privateKeyPath,
        '-out',
        sigFile,
        dataFile.path,
      ]);

      if (result.exitCode != 0) {
        _logger.err('Signing failed: ${result.stderr}');
        return null;
      }

      return File(sigFile).readAsBytesSync();
    } finally {
      tempDir.deleteSync(recursive: true);
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
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      _logger.err('Build tool not available. Run "fcp codepush setup" first.');
      return false;
    }
    final result = Process.runSync(tool, ['prepare', buildPlatform]);
    if (result.exitCode != 0) {
      _logger.err('Build preparation failed.');
    }
    return result.exitCode == 0;
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
