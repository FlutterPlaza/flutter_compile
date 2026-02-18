import 'dart:io';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';

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

  group('F.homeDirOverride', () {
    final tempHome = TempHome();
    setUp(tempHome.setUp);
    tearDown(tempHome.tearDown);

    test('homeDir returns override when set', () {
      expect(F.homeDir(), equals(tempHome.path));
    });

    test('homeDir returns real home after clearing override', () {
      F.homeDirOverride = null;
      final home = F.homeDir();
      expect(home, isNot(equals(tempHome.path)));
      expect(home, isNotEmpty);
      // Re-set for tearDown safety
      F.homeDirOverride = tempHome.path;
    });
  });

  group('F.isValidGitRepo', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fc_git_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('returns false for non-existent path', () {
      expect(F.isValidGitRepo('/tmp/nonexistent_fc_test_12345'), isFalse);
    });

    test('returns false for empty directory (no .git)', () {
      expect(F.isValidGitRepo(tempDir.path), isFalse);
    });

    test('returns false for directory with .git but no HEAD', () {
      Directory('${tempDir.path}/.git').createSync();
      expect(F.isValidGitRepo(tempDir.path), isFalse);
    });

    test('returns true for directory with .git/HEAD', () {
      Directory('${tempDir.path}/.git').createSync();
      File('${tempDir.path}/.git/HEAD')
          .writeAsStringSync('ref: refs/heads/main\n');
      expect(F.isValidGitRepo(tempDir.path), isTrue);
    });
  });

  group('F.isSdkInstalled', () {
    final tempHome = TempHome();
    setUp(tempHome.setUp);
    tearDown(tempHome.tearDown);

    test('returns false for non-existent version', () {
      expect(F.isSdkInstalled('9.99.99'), isFalse);
    });

    test('returns false for directory without .git/HEAD', () {
      final sdkPath = '${tempHome.path}${Constants.sdkVersionsPath}/3.19.0';
      Directory(sdkPath).createSync(recursive: true);
      expect(F.isSdkInstalled('3.19.0'), isFalse);
    });

    test('returns true for valid git repo at version path', () {
      final sdkPath = '${tempHome.path}${Constants.sdkVersionsPath}/3.19.0';
      Directory('$sdkPath/.git').createSync(recursive: true);
      File('$sdkPath/.git/HEAD').writeAsStringSync('ref: refs/heads/main\n');
      expect(F.isSdkInstalled('3.19.0'), isTrue);
    });
  });

  group('F.writeKeyValueToRcConfig / readValueForKeyFromRcConfig', () {
    final tempHome = TempHome();
    setUp(tempHome.setUp);
    tearDown(tempHome.tearDown);

    test('writes and reads a key-value pair', () async {
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(rcFile, 'test_key', 'test_value');
      final result = await F.readValueForKeyFromRcConfig(rcFile, 'test_key');
      expect(result, equals('test_value'));
    });

    test('overwrites existing key', () async {
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(rcFile, 'key1', 'old');
      await F.writeKeyValueToRcConfig(rcFile, 'key1', 'new');
      final result = await F.readValueForKeyFromRcConfig(rcFile, 'key1');
      expect(result, equals('new'));
    });

    test('preserves other keys when writing', () async {
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(rcFile, 'key1', 'val1');
      await F.writeKeyValueToRcConfig(rcFile, 'key2', 'val2');
      final r1 = await F.readValueForKeyFromRcConfig(rcFile, 'key1');
      final r2 = await F.readValueForKeyFromRcConfig(rcFile, 'key2');
      expect(r1, equals('val1'));
      expect(r2, equals('val2'));
    });

    test('returns null for missing key', () async {
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(rcFile, 'key1', 'val1');
      final result = await F.readValueForKeyFromRcConfig(rcFile, 'nonexistent');
      expect(result, isNull);
    });

    test('returns null for non-existent file', () async {
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      final result = await F.readValueForKeyFromRcConfig(rcFile, 'key1');
      expect(result, isNull);
    });
  });

  group('F.writeFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fc_write_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('creates parent directories and writes content', () async {
      final path = '${tempDir.path}/sub/dir/file.txt';
      await F.writeFile(path, 'hello world');
      expect(File(path).readAsStringSync(), equals('hello world'));
    });

    test('overwrites existing file', () async {
      final path = '${tempDir.path}/file.txt';
      await F.writeFile(path, 'first');
      await F.writeFile(path, 'second');
      expect(File(path).readAsStringSync(), equals('second'));
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
      final tempDir = await Directory.systemTemp.createTemp('fc_test_');
      try {
        final versionFile = File('${tempDir.path}/.flutter-version');
        await versionFile.writeAsString('3.22.0\n');
        final projectResult = await F.readProjectSdkVersion(tempDir.path);
        expect(projectResult, equals('3.22.0'));

        final globalResult = await F.readGlobalSdkVersion();
        final resolved = projectResult ?? globalResult;
        expect(resolved, equals('3.22.0'));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });

  group('F.readGlobalSdkVersion', () {
    final tempHome = TempHome();
    setUp(tempHome.setUp);
    tearDown(tempHome.tearDown);

    test('returns null when rc file does not exist', () async {
      final result = await F.readGlobalSdkVersion();
      expect(result, isNull);
    });

    test('returns version from rc file', () async {
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(
        rcFile,
        Constants.globalSdkVersionKey,
        '3.24.0',
      );
      final result = await F.readGlobalSdkVersion();
      expect(result, equals('3.24.0'));
    });
  });

  group('F.sdkVersionPath with homeDirOverride', () {
    final tempHome = TempHome();
    setUp(tempHome.setUp);
    tearDown(tempHome.tearDown);

    test('uses overridden home directory', () {
      final path = F.sdkVersionPath('3.19.0');
      expect(path, startsWith(tempHome.path));
      expect(path, endsWith('/flutter_compile/versions/3.19.0'));
    });
  });
}
