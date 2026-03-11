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

  /// .vmcode magic bytes: "VMCODE\0\0".
  /// Matches the engine's vmcode_builder.dart format.
  static const vmcodeMagic = [0x56, 0x4D, 0x43, 0x4F, 0x44, 0x45, 0x00, 0x00];

  /// .vmcode format version.
  static const vmcodeVersion = 1;

  /// Size of the fixed .vmcode header (before signature).
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
  /// Returns the path to the build output directory, or null on failure.
  Future<String?> buildRelease({
    required String platform,
    List<String> extraArgs = const [],
  }) async {
    final flutter = findFlutterBin();
    if (flutter == null) {
      _logger.err('Flutter not found on PATH.');
      return null;
    }

    final args = ['build', platform, '--release', ...extraArgs];
    _logger.detail('Running: flutter ${args.join(' ')}');

    final process = await Process.start(flutter, args, mode: ProcessStartMode.inheritStdio);
    final exitCode = await process.exitCode;

    if (exitCode != 0) {
      _logger.err('Flutter build failed with exit code $exitCode');
      return null;
    }

    return findSnapshotPath(platform);
  }

  /// Find the AOT snapshot in the build output.
  String? findSnapshotPath(String platform) {
    final Map<String, List<String>> platformPaths = {
      'apk': [
        'build/app/intermediates/flutter/release/app.so',
        'build/app/intermediates/stripped_native_libs/release/out/lib/arm64-v8a/libapp.so',
        'build/app/intermediates/stripped_native_libs/release/out/lib/armeabi-v7a/libapp.so',
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
  ///
  /// Compatible with the engine's `vmcode_builder.dart` format:
  /// ```
  /// Offset  Size    Content
  /// 0       8       Magic: "VMCODE\0\0"
  /// 8       4       Format version (uint32, little-endian)
  /// 12      4       Payload offset (uint32, little-endian)
  /// 16      32      SHA-256 hash of payload
  /// 48      4       Signature length (uint32, little-endian)
  /// 52      N       RSA signature (empty for unsigned)
  /// 52+N    ...     Payload (kernel .dill or binary diff)
  /// ```
  Uint8List packageVmcode(Uint8List payload, {Uint8List? signature}) {
    signature ??= Uint8List(0);

    final hashBytes = sha256.convert(payload).bytes;
    final payloadOffset = vmcodeHeaderSize + signature.length;

    final header = ByteData(vmcodeHeaderSize);
    // Magic: "VMCODE\0\0"
    for (var i = 0; i < 8; i++) {
      header.setUint8(i, vmcodeMagic[i]);
    }
    // Version (little-endian uint32).
    header.setUint32(8, vmcodeVersion, Endian.little);
    // Payload offset (little-endian uint32).
    header.setUint32(12, payloadOffset, Endian.little);
    // SHA-256 hash (32 bytes).
    for (var i = 0; i < 32; i++) {
      header.setUint8(16 + i, hashBytes[i]);
    }
    // Signature length (little-endian uint32).
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

    // Check magic.
    for (var i = 0; i < 8; i++) {
      if (vmcodeData[i] != vmcodeMagic[i]) {
        _logger.err('Invalid .vmcode magic bytes');
        return null;
      }
    }

    final bd = vmcodeData.buffer.asByteData(vmcodeData.offsetInBytes);

    // Check version.
    final version = bd.getUint32(8, Endian.little);
    if (version != vmcodeVersion) {
      _logger.err('Unsupported .vmcode version: $version');
      return null;
    }

    // Read payload offset and hash.
    final payloadOffset = bd.getUint32(12, Endian.little);
    final storedHash = vmcodeData.sublist(16, 48);

    if (payloadOffset > vmcodeData.length) {
      _logger.err('.vmcode payload offset exceeds file size');
      return null;
    }

    final payload = vmcodeData.sublist(payloadOffset);

    // Verify hash.
    final computedHash = sha256.convert(payload).bytes;
    for (var i = 0; i < 32; i++) {
      if (storedHash[i] != computedHash[i]) {
        _logger.err('.vmcode integrity check failed — hash mismatch');
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
        'dgst', '-sha256', '-sign', privateKeyPath,
        '-out', sigFile, dataFile.path,
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
      'genrsa', '-out', privatePath, '2048',
    ]);
    if (result.exitCode != 0) {
      _logger.err('Key generation failed: ${result.stderr}');
      return null;
    }

    result = Process.runSync('openssl', [
      'rsa', '-in', privatePath, '-pubout', '-out', publicPath,
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
      final candidate = '$flutterDir/bin/cache/artifacts/engine/$os-$arch/gen_snapshot';
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
}
