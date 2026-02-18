import 'dart:io';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';
import '../../helpers/test_helpers.dart';

void main() {
  group('installSdk behavioral', () {
    final tempHome = TempHome();
    late Logger logger;

    setUp(() {
      tempHome.setUp();
      logger = MockLogger();
      when(() => logger.info(any())).thenReturn(null);
      when(() => logger.success(any())).thenReturn(null);
      when(() => logger.err(any())).thenReturn(null);
      when(() => logger.progress(any())).thenReturn(MockProgress());
      F.logger = logger;
    });

    tearDown(() {
      F.logger = Logger();
      tempHome.tearDown();
    });

    test('isSdkInstalled returns false for partial directory without .git/HEAD',
        () {
      final sdkPath = '${tempHome.path}${Constants.sdkVersionsPath}/3.19.0';
      Directory(sdkPath).createSync(recursive: true);
      // Directory exists but no .git/HEAD — not valid
      expect(F.isSdkInstalled('3.19.0'), isFalse);
    });

    test('isSdkInstalled returns true for valid git repo', () {
      final sdkPath = '${tempHome.path}${Constants.sdkVersionsPath}/3.19.0';
      Directory('$sdkPath/.git').createSync(recursive: true);
      File('$sdkPath/.git/HEAD').writeAsStringSync('ref: refs/heads/main\n');
      expect(F.isSdkInstalled('3.19.0'), isTrue);
    });

    test('cloneRepository skips when valid git repo exists and force=false',
        () async {
      final dir = Directory('${tempHome.path}/repo');
      Directory('${dir.path}/.git').createSync(recursive: true);
      File('${dir.path}/.git/HEAD').writeAsStringSync('ref: refs/heads/main\n');

      await F.cloneRepository('https://example.com/repo.git', dir.path);
      // Should have skipped — verify the info message
      verify(
        () => logger.info(
          'Directory ${dir.path} already exists. Skipping clone.',
        ),
      ).called(1);
    });

    test('cloneRepository cleans up invalid repo directory and re-clones',
        () async {
      final dir = Directory('${tempHome.path}/repo');
      dir.createSync();
      // No .git/HEAD — invalid repo

      // The actual clone will fail because the URL is fake,
      // but we verify the cleanup-and-reclone path was taken
      try {
        await F.cloneRepository(
          'https://invalid.example.com/repo.git',
          dir.path,
        );
      } catch (_) {
        // Expected: git clone fails for invalid URL
      }

      // The invalid directory should have been cleaned up by the catch block
      verify(
        () => logger.info(
          'Directory ${dir.path} exists but is not a valid git repo. '
          'Cleaning up and re-cloning...',
        ),
      ).called(1);
    });
  });
}
