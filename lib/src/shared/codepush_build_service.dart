import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

import 'codepush_artifact_manager.dart';

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
  Future<bool> finalizeBuild({
    required String buildPlatform,
    String? flutterVersion,
    required CodePushArtifactManager artifactManager,
  }) async {
    final tool = await artifactManager.ensureBuildTool();
    if (tool == null) {
      _logger.err('Build tool not available.');
      return false;
    }
    final args = <String>[
      'finalize',
      buildPlatform,
      if (flutterVersion != null) ...['--flutter-version', flutterVersion],
    ];
    final result = Process.runSync(tool, args);
    if (result.exitCode != 0) {
      _logger.err('Build finalization failed.');
    }
    return result.exitCode == 0;
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
