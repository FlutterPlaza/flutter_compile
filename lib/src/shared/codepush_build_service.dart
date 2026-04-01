import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

import 'codepush_artifact_manager.dart';

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

  static const vmcodeMagic = [0x56, 0x4D, 0x43, 0x4F, 0x44, 0x45, 0x00, 0x00];
  static const vmcodeVersion = 1;
  static const vmcodeHeaderSize = 52;

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

  /// Package payload into .vmcode format.
  Uint8List packageVmcode(Uint8List payload, {Uint8List? signature}) {
    signature ??= Uint8List(0);

    final hashBytes = sha256.convert(payload).bytes;
    final payloadOffset = vmcodeHeaderSize + signature.length;

    final header = ByteData(vmcodeHeaderSize);
    for (var i = 0; i < 8; i++) {
      header.setUint8(i, vmcodeMagic[i]);
    }
    header.setUint32(8, vmcodeVersion, Endian.little);
    header.setUint32(12, payloadOffset, Endian.little);
    for (var i = 0; i < 32; i++) {
      header.setUint8(16 + i, hashBytes[i]);
    }
    header.setUint32(48, signature.length, Endian.little);

    final buffer = BytesBuilder();
    buffer.add(header.buffer.asUint8List());
    buffer.add(signature);
    buffer.add(payload);

    return buffer.toBytes();
  }

  /// Verify and extract payload from a .vmcode file.
  Uint8List? extractVmcode(Uint8List vmcodeData) {
    if (vmcodeData.length < vmcodeHeaderSize) {
      _logger.err('.vmcode file too small');
      return null;
    }

    for (var i = 0; i < 8; i++) {
      if (vmcodeData[i] != vmcodeMagic[i]) {
        _logger.err('Invalid .vmcode magic bytes');
        return null;
      }
    }

    final bd = vmcodeData.buffer.asByteData(vmcodeData.offsetInBytes);
    final version = bd.getUint32(8, Endian.little);
    if (version != vmcodeVersion) {
      _logger.err('Unsupported .vmcode version: $version');
      return null;
    }

    final payloadOffset = bd.getUint32(12, Endian.little);
    final storedHash = vmcodeData.sublist(16, 48);

    if (payloadOffset > vmcodeData.length) {
      _logger.err('.vmcode payload offset exceeds file size');
      return null;
    }

    final payload = vmcodeData.sublist(payloadOffset);

    final computedHash = sha256.convert(payload).bytes;
    for (var i = 0; i < 32; i++) {
      if (storedHash[i] != computedHash[i]) {
        _logger.err('.vmcode integrity check failed');
        return null;
      }
    }

    return Uint8List.fromList(payload);
  }

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

  /// Find the gen_snapshot binary from the Dart SDK fork.
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
      _logger.err('gen_snapshot not found. Ensure the Dart SDK fork is built.');
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

  /// Swap the engine library in an Android APK build output.
  ///
  /// Replaces `libflutter.so` in the native libs directory with the
  /// code-push-enabled version from the artifact cache.
  ///
  /// Returns true on success.
  bool swapAndroidEngine(String cachedLibFlutter) {
    // Android native libs location (arm64-v8a for arm64).
    final candidates = [
      'build/app/intermediates/stripped_native_libs/release/out/lib/arm64-v8a/libflutter.so',
      'build/app/intermediates/merged_native_libs/release/out/lib/arm64-v8a/libflutter.so',
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        final backup = File('$candidate.original');
        if (!backup.existsSync()) {
          file.copySync(backup.path);
        }
        File(cachedLibFlutter).copySync(candidate);
        _logger.detail('Swapped Android engine: $candidate');
        return true;
      }
    }

    // Also check the unstripped location used by some build configs.
    final jniDir = Directory(
      'build/app/intermediates/flutter/release/jniLibs/arm64-v8a',
    );
    if (jniDir.existsSync()) {
      final target = '${jniDir.path}/libflutter.so';
      final backup = File('$target.original');
      final existing = File(target);
      if (existing.existsSync() && !backup.existsSync()) {
        existing.copySync(backup.path);
      }
      File(cachedLibFlutter).copySync(target);
      _logger.detail('Swapped Android engine: $target');
      return true;
    }

    _logger.err('Could not find libflutter.so in Android build output.');
    return false;
  }

  /// Swap the engine framework in an iOS build output.
  ///
  /// Replaces `Flutter.framework` (or `Flutter.xcframework`) in the
  /// iOS build output with the code-push-enabled version.
  ///
  /// [cachedFrameworkArchive] is the path to `Flutter.xcframework.tar.gz`.
  ///
  /// Returns true on success.
  Future<bool> swapIosEngine(String cachedFrameworkArchive) async {
    // iOS framework locations.
    final candidates = [
      'build/ios/Release-iphoneos/Runner.app/Frameworks/Flutter.framework',
      'build/ios/iphoneos/Runner.app/Frameworks/Flutter.framework',
    ];

    String? targetDir;
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        targetDir = candidate;
        break;
      }
    }

    if (targetDir == null) {
      _logger.err(
        'Could not find Flutter.framework in iOS build output.',
      );
      return false;
    }

    // Extract xcframework to a temp location.
    final tempDir = Directory.systemTemp.createTempSync('fcp_ios_swap_');
    try {
      final extractResult = await Process.run(
        'tar',
        ['xzf', cachedFrameworkArchive, '-C', tempDir.path],
      );
      if (extractResult.exitCode != 0) {
        _logger.err('Failed to extract Flutter.xcframework');
        return false;
      }

      // Find the ios-arm64 framework inside the xcframework.
      final xcfwDir = Directory('${tempDir.path}/Flutter.xcframework');
      if (!xcfwDir.existsSync()) {
        _logger.err('Flutter.xcframework not found in archive');
        return false;
      }

      // Look for the arm64 slice.
      String? slicePath;
      for (final entry in xcfwDir.listSync()) {
        if (entry is Directory && entry.path.contains('ios-arm64')) {
          final fw = Directory('${entry.path}/Flutter.framework');
          if (fw.existsSync()) {
            slicePath = fw.path;
            break;
          }
        }
      }

      if (slicePath == null) {
        _logger.err(
          'No ios-arm64 slice found in Flutter.xcframework',
        );
        return false;
      }

      // Backup original and replace.
      final backupDir = Directory('$targetDir.original');
      if (!backupDir.existsSync()) {
        Directory(targetDir).renameSync(backupDir.path);
      } else {
        Directory(targetDir).deleteSync(recursive: true);
      }

      // Copy the new framework.
      await _copyDirectory(Directory(slicePath), Directory(targetDir));
      _logger.detail('Swapped iOS engine: $targetDir');
      return true;
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  }

  /// Swap the engine library on macOS.
  bool swapMacosEngine(String cachedLibFlutterEngine) {
    final candidate =
        'build/macos/Build/Products/Release/Runner.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A/FlutterMacOS';
    final file = File(candidate);
    if (file.existsSync()) {
      final backup = File('$candidate.original');
      if (!backup.existsSync()) {
        file.copySync(backup.path);
      }
      File(cachedLibFlutterEngine).copySync(candidate);
      _logger.detail('Swapped macOS engine: $candidate');
      return true;
    }

    _logger.err('Could not find FlutterMacOS in macOS build output.');
    return false;
  }

  /// Swap the engine library on Linux.
  bool swapLinuxEngine(String cachedLibFlutter) {
    final candidates = [
      'build/linux/x64/release/bundle/lib/libflutter_linux_gtk.so',
      'build/linux/arm64/release/bundle/lib/libflutter_linux_gtk.so',
    ];

    for (final candidate in candidates) {
      final file = File(candidate);
      if (file.existsSync()) {
        final backup = File('$candidate.original');
        if (!backup.existsSync()) {
          file.copySync(backup.path);
        }
        File(cachedLibFlutter).copySync(candidate);
        _logger.detail('Swapped Linux engine: $candidate');
        return true;
      }
    }

    _logger
        .err('Could not find libflutter_linux_gtk.so in Linux build output.');
    return false;
  }

  /// Swap the engine library on Windows.
  bool swapWindowsEngine(String cachedFlutterEngineDll) {
    final candidate = 'build/windows/x64/runner/Release/flutter_windows.dll';
    final file = File(candidate);
    if (file.existsSync()) {
      final backup = File('$candidate.original');
      if (!backup.existsSync()) {
        file.copySync(backup.path);
      }
      File(cachedFlutterEngineDll).copySync(candidate);
      _logger.detail('Swapped Windows engine: $candidate');
      return true;
    }

    _logger.err(
      'Could not find flutter_windows.dll in Windows build output.',
    );
    return false;
  }

  /// Swap engine for a given build platform using cached artifacts.
  ///
  /// Looks up the cached engine library for [flutterVersion] and
  /// [buildPlatform], then replaces it in the build output.
  ///
  /// Returns true on success, false if artifacts not found or swap failed.
  Future<bool> swapEngine({
    required String buildPlatform,
    required String flutterVersion,
    required CodePushArtifactManager artifactManager,
  }) async {
    final artifactPlatform =
        CodePushArtifactManager.buildPlatformToArtifactPlatform(buildPlatform);
    if (artifactPlatform == null) {
      _logger.err('Unknown build platform: $buildPlatform');
      return false;
    }

    // For mobile builds, we also need the host platform gen_snapshot.
    // The engine library (libflutter.so / Flutter.framework) is a cross-compiled
    // artifact from the mobile platform directory.
    final engineLib = artifactManager.engineLibraryPath(
      flutterVersion,
      platform: artifactPlatform,
    );
    if (engineLib == null) {
      _logger.err(
        'Cached engine library not found for '
        '$artifactPlatform (Flutter $flutterVersion). '
        'Run "fcp codepush setup --flutter-version $flutterVersion '
        '--platform $artifactPlatform" first.',
      );
      return false;
    }

    switch (buildPlatform) {
      case 'apk':
      case 'appbundle':
      case 'android':
        return swapAndroidEngine(engineLib);
      case 'ios':
        return swapIosEngine(engineLib);
      case 'macos':
        return swapMacosEngine(engineLib);
      case 'linux':
        return swapLinuxEngine(engineLib);
      case 'windows':
        return swapWindowsEngine(engineLib);
      default:
        _logger.err('Engine swap not supported for platform: $buildPlatform');
        return false;
    }
  }

  /// Recursively copy a directory.
  Future<void> _copyDirectory(Directory source, Directory dest) async {
    if (!dest.existsSync()) {
      dest.createSync(recursive: true);
    }
    await for (final entity in source.list(recursive: false)) {
      final newPath = '${dest.path}/${entity.uri.pathSegments.last}';
      if (entity is File) {
        entity.copySync(newPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      }
    }
  }
}
