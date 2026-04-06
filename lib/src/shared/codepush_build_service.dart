import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

import 'codepush_artifact_manager.dart';
import 'constants.dart';

/// Build service for code push operations.
///
/// Handles:
/// - Finding the Flutter/Dart SDK tools
/// - Building AOT snapshots for releases
/// - Compiling Dart kernel (.dill) for patches
/// - Packaging patches into .vmcode format
class CodePushBuildService {
  CodePushBuildService({required Logger logger}) : _logger = logger;

  final Logger _logger;

  // Patch format constants are handled by the fcp-tool binary.

  /// Find the `flutter` executable.
  String? findFlutterBin() {
    // Check if flutter is on PATH.
    final result = Process.runSync('which', ['flutter']);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
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

  /// Find the frontend_server snapshot for kernel compilation.
  String? findFrontendServer() {
    final dartBin = findDartBin();
    if (dartBin == null) return null;

    // frontend_server is typically at:
    // <dart-sdk>/bin/snapshots/frontend_server_aot.dart.snapshot
    // or relative to the flutter cache:
    // <flutter>/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot
    final dartDir = File(dartBin).parent.path;
    final candidates = [
      '$dartDir/snapshots/frontend_server_aot.dart.snapshot',
      '$dartDir/snapshots/frontend_server.dart.snapshot',
    ];

    // Also check flutter cache location.
    final flutterBin = findFlutterBin();
    if (flutterBin != null) {
      final flutterDir = File(flutterBin).parent.parent.path;
      candidates.addAll([
        '$flutterDir/bin/cache/artifacts/engine/common/frontend_server.dart.snapshot',
        '$flutterDir/bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot',
        '$flutterDir/bin/cache/dart-sdk/bin/snapshots/frontend_server.dart.snapshot',
      ]);
    }

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    return null;
  }

  /// Build a Flutter app in release mode.
  ///
  /// Returns true if the build succeeded, false otherwise.
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

  /// Find the AOT snapshot in the build output.
  String? findSnapshotPath(String platform) {
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
      'ios': [
        'build/ios/Release-iphoneos/Runner.app/Frameworks/App.framework/App',
        'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App',
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
    // Also add the generic candidates.
    candidates.addAll([
      'build/app/intermediates/flutter/release/app.so',
      'build/ios/Release/App.framework/App',
      'build/linux/x64/release/bundle/lib/libapp.so',
    ]);

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }

    return null;
  }

  /// Compile the current project's Dart source to a kernel (.dill) file.
  ///
  /// This produces the bytecode that the VM interpreter can execute.
  /// The kernel file contains all the application code in a form that
  /// can be loaded at runtime via BytecodeLoader.
  Future<String?> compileKernel({String? outputPath}) async {
    final dart = findDartBin();
    if (dart == null) {
      _logger.err('Dart SDK not found on PATH.');
      return null;
    }

    // Find the main entry point.
    final mainCandidates = [
      'lib/main.dart',
      'lib/app.dart',
    ];

    String? mainFile;
    for (final candidate in mainCandidates) {
      if (File(candidate).existsSync()) {
        mainFile = candidate;
        break;
      }
    }

    if (mainFile == null) {
      _logger.err('No main.dart found. Run from your Flutter project root.');
      return null;
    }

    final output = outputPath ?? 'build/codepush/app.dill';
    final outputDir = File(output).parent;
    if (!outputDir.existsSync()) {
      outputDir.createSync(recursive: true);
    }

    // Use `dart compile kernel` to produce the kernel file.
    final args = ['compile', 'kernel', '-o', output, mainFile];
    _logger.detail('Running: dart ${args.join(' ')}');

    final result = await Process.run(dart, args);

    if (result.exitCode != 0) {
      _logger.err('Kernel compilation failed:');
      _logger.err(result.stderr as String);
      return null;
    }

    if (!File(output).existsSync()) {
      _logger.err('Expected kernel output not found at $output');
      return null;
    }

    final size = File(output).lengthSync();
    _logger.detail('Kernel compiled: $output ($size bytes)');
    return output;
  }

  // Patch packaging and extraction are handled by the fcp-tool binary.

  /// Sign data with RSA-SHA256 using a PEM private key file.
  /// Returns the signature bytes, or null if signing fails.
  Future<Uint8List?> signPayload(Uint8List data, String privateKeyPath) async {
    final keyFile = File(privateKeyPath);
    if (!keyFile.existsSync()) {
      _logger.err('Signing key not found: $privateKeyPath');
      return null;
    }
    // Use openssl for portability - avoids heavy pointycastle dependency
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
  /// Returns (privateKeyPath, publicKeyPath), or null on failure.
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

  /// Find the gen_snapshot binary for deterministic builds.
  /// Checks code push artifact cache first, then the contribution Flutter SDK,
  /// then falls back to PATH.
  String? findGenSnapshot() {
    // 1. Check the code push artifact cache (downloaded via `fcp codepush setup`).
    final artifactManager = CodePushArtifactManager(logger: _logger);
    final cachedGenSnapshot = artifactManager.findCachedGenSnapshot();
    if (cachedGenSnapshot != null) {
      _logger.detail('Using cached code-push gen_snapshot: $cachedGenSnapshot');
      return cachedGenSnapshot;
    }

    // 2. Check flutter_compile's configured paths.
    final home = Platform.environment['HOME'] ?? '/tmp';
    final rcFile = File('$home/.flutter_compilerc');

    if (rcFile.existsSync()) {
      final content = rcFile.readAsStringSync();
      // Look for the contribution Flutter SDK's gen_snapshot
      for (final line in content.split('\n')) {
        if (line.startsWith('flutter_path:') || line.startsWith('fc_path:')) {
          final path = line.split(':').skip(1).join(':').trim();
          // gen_snapshot is in the engine build output or cache
          final candidates = [
            '$path/bin/cache/artifacts/engine/darwin-x64/gen_snapshot',
            '$path/bin/cache/artifacts/engine/darwin-arm64/gen_snapshot',
            '$path/bin/cache/artifacts/engine/linux-x64/gen_snapshot',
            '$path/../dart-sdk/out/ReleaseX64/gen_snapshot',
            '$path/../dart-sdk/out/ReleaseARM64/gen_snapshot',
          ];
          for (final candidate in candidates) {
            if (File(candidate).existsSync()) return candidate;
          }
        }
      }
    }

    // Fall back to whatever is on PATH via the Flutter cache
    final flutter = findFlutterBin();
    if (flutter != null) {
      final flutterDir = File(flutter).parent.parent.path;
      final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
      final os = Platform.isMacOS ? 'darwin' : 'linux';
      final candidate =
          '$flutterDir/bin/cache/artifacts/engine/$os-$arch/gen_snapshot';
      if (File(candidate).existsSync()) return candidate;
    }

    return null;
  }

  /// Run gen_snapshot with --stable_object_pool_indices to produce
  /// deterministic AOT output.
  Future<String?> buildDeterministicSnapshot({
    required String inputPath,
    required String outputPath,
    List<String> extraArgs = const [],
  }) async {
    final genSnapshot = findGenSnapshot();
    if (genSnapshot == null) {
      _logger.err('gen_snapshot not found. Run "fcp codepush setup" first.');
      return null;
    }

    final outputDir = File(outputPath).parent;
    if (!outputDir.existsSync()) {
      outputDir.createSync(recursive: true);
    }

    final args = [
      '--deterministic',
      '--stable_object_pool_indices',
      '--snapshot-kind=app-aot-elf',
      '--elf=$outputPath',
      ...extraArgs,
      inputPath,
    ];

    _logger.detail('Running: $genSnapshot ${args.join(' ')}');

    final result = await Process.run(genSnapshot, args);
    if (result.exitCode != 0) {
      _logger.err('gen_snapshot failed:');
      _logger.err(result.stderr as String);
      return null;
    }

    if (!File(outputPath).existsSync()) {
      _logger.err('gen_snapshot produced no output at $outputPath');
      return null;
    }

    final size = File(outputPath).lengthSync();
    _logger.detail('Deterministic snapshot: $outputPath ($size bytes)');
    return outputPath;
  }

  /// Compute SHA-256 hash of data, returned as hex string.
  String computeHash(List<int> data) {
    return sha256.convert(data).toString();
  }

  /// Get the platform string from the current project.
  String? detectPlatform() {
    // Check for android/ios/linux/macos/windows directories.
    if (Directory('android').existsSync()) return 'apk';
    if (Directory('ios').existsSync()) return 'ios';
    if (Directory('linux').existsSync()) return 'linux';
    if (Directory('macos').existsSync()) return 'macos';
    if (Directory('windows').existsSync()) return 'windows';
    return null;
  }

  // ── Engine swap logic ───────────────────────────────────────────
  // Engine swap, gen_snapshot swap, and build tool management are handled
  // by the fcp-tool binary. See `fcp codepush setup` for details.

  /// Prepare the build for code push.
  ///
  /// Swaps the Flutter SDK's gen_snapshot with our code-push version so that
  /// the AOT snapshot compiled by `flutter build` matches the code-push engine
  /// runtime. Also runs a pre-compiled build tool to swap the engine library
  /// in the build output.
  /// Prepare the build for code push.
  ///
  /// Delegates to the fcp-tool binary which handles engine and
  /// gen_snapshot swapping.
  Future<bool> prepareBuild({
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

  /// Swap the engine library in the build output AFTER `flutter build`.
  ///
  /// Delegates to the fcp-tool binary.
  Future<bool> swapEngineLibrary({
    required String buildPlatform,
    String? flutterVersion,
    required CodePushArtifactManager artifactManager,
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      _logger.err('Build tool not available.');
      return false;
    }
    final result = Process.runSync(tool, ['swap-engine', buildPlatform]);
    if (result.exitCode != 0) {
      _logger.err('Engine swap failed.');
    }
    return result.exitCode == 0;
  }
}
