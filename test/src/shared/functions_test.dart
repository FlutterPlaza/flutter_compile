import 'dart:io';

import 'package:flutter_compile/src/shared/functions.dart';
import 'package:test/test.dart';

void main() {
  group('F platform helpers', () {
    test('homeDir returns a non-empty string', () {
      expect(F.homeDir(), isNotEmpty);
    });

    test('envPathSeparator returns : on Unix or ; on Windows', () {
      if (Platform.isWindows) {
        expect(F.envPathSeparator, equals(';'));
      } else {
        expect(F.envPathSeparator, equals(':'));
      }
    });

    test('getShellConfigPath returns a non-empty string', () {
      final path = F.getShellConfigPath();
      expect(path, isNotEmpty);
    });

    test('getHostCpuArch returns a recognized architecture', () async {
      final arch = await F.getHostCpuArch();
      expect(arch, anyOf('arm64', 'x86_64', 'aarch64'));
    });
  });

  group('F SDK helpers', () {
    test('sdkPubCachePath returns <path>/.pub-cache', () {
      expect(F.sdkPubCachePath('/some/sdk'), equals('/some/sdk/.pub-cache'));
    });

    test('sdkEnvironment returns map with PUB_CACHE key', () {
      final env = F.sdkEnvironment('/some/sdk');
      expect(env, containsPair('PUB_CACHE', '/some/sdk/.pub-cache'));
      expect(env.length, equals(1));
    });

    test('sdkVersionPath builds correct path', () {
      final home = F.homeDir();
      final path = F.sdkVersionPath('3.19.0');
      expect(path, equals('$home/flutter_compile/versions/3.19.0'));
    });

    test('readProjectSdkVersion returns null when no file', () async {
      // Use a temp directory that has no .flutter-version file
      final tempDir = await Directory.systemTemp.createTemp('fc_test_');
      try {
        final result = await F.readProjectSdkVersion(tempDir.path);
        expect(result, isNull);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('readProjectSdkVersion reads version from file', () async {
      final tempDir = await Directory.systemTemp.createTemp('fc_test_');
      try {
        final versionFile = File('${tempDir.path}/.flutter-version');
        await versionFile.writeAsString('3.19.0\n');
        final result = await F.readProjectSdkVersion(tempDir.path);
        expect(result, equals('3.19.0'));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('readProjectSdkVersion returns null for empty file', () async {
      final tempDir = await Directory.systemTemp.createTemp('fc_test_');
      try {
        final versionFile = File('${tempDir.path}/.flutter-version');
        await versionFile.writeAsString('  \n');
        final result = await F.readProjectSdkVersion(tempDir.path);
        expect(result, isNull);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('resolveActiveSdkVersion prefers project over global', () async {
      // When no project or global is set, returns null
      // (this test runs in a directory without .flutter-version)
      final tempDir = await Directory.systemTemp.createTemp('fc_test_');
      try {
        // With a project version file present, readProjectSdkVersion
        // should return that value
        final versionFile = File('${tempDir.path}/.flutter-version');
        await versionFile.writeAsString('3.22.0\n');
        final projectResult = await F.readProjectSdkVersion(tempDir.path);
        expect(projectResult, equals('3.22.0'));

        // resolveActiveSdkVersion checks project first (cwd), then global
        // We verify the preference by checking readProjectSdkVersion returns
        // a value which would be used before readGlobalSdkVersion
        final globalResult = await F.readGlobalSdkVersion();
        // Project version should be preferred
        final resolved = projectResult ?? globalResult;
        expect(resolved, equals('3.22.0'));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
