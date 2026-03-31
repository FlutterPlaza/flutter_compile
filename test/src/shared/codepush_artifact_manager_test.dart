import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  group('CodePushArtifactManager', () {
    late MockLogger logger;
    late Directory tempDir;
    late CodePushArtifactManager manager;

    setUp(() {
      logger = MockLogger();
      tempDir = Directory.systemTemp.createTempSync('artifact_test_');
      manager = CodePushArtifactManager(
        logger: logger,
        cacheRoot: tempDir.path,
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    group('platforms', () {
      test('includes host platforms', () {
        expect(
          CodePushArtifactManager.hostPlatforms,
          containsAll([
            'darwin-arm64',
            'darwin-x64',
            'linux-x64',
            'windows-x64',
          ]),
        );
      });

      test('includes mobile platforms', () {
        expect(
          CodePushArtifactManager.mobilePlatforms,
          containsAll(['android-arm64', 'ios-arm64']),
        );
      });

      test('platforms is superset of host + mobile', () {
        expect(
          CodePushArtifactManager.platforms,
          containsAll([
            ...CodePushArtifactManager.hostPlatforms,
            ...CodePushArtifactManager.mobilePlatforms,
          ]),
        );
      });
    });

    group('buildPlatformToArtifactPlatform', () {
      test('maps apk to android-arm64', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('apk'),
          equals('android-arm64'),
        );
      });

      test('maps appbundle to android-arm64', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('appbundle'),
          equals('android-arm64'),
        );
      });

      test('maps android to android-arm64', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('android'),
          equals('android-arm64'),
        );
      });

      test('maps ios to ios-arm64', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('ios'),
          equals('ios-arm64'),
        );
      });

      test('maps linux to linux-x64', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('linux'),
          equals('linux-x64'),
        );
      });

      test('maps windows to windows-x64', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('windows'),
          equals('windows-x64'),
        );
      });

      test('returns null for unknown', () {
        expect(
          CodePushArtifactManager.buildPlatformToArtifactPlatform('web'),
          isNull,
        );
      });
    });

    group('versionDir', () {
      test('returns correct path', () {
        expect(
          manager.versionDir('3.24.0'),
          equals('${tempDir.path}/flutter-3.24.0'),
        );
      });
    });

    group('isVersionCached', () {
      test('returns false when no stamp file', () {
        expect(manager.isVersionCached('3.24.0'), isFalse);
      });

      test('returns true when stamp file exists', () {
        final dir = Directory('${tempDir.path}/flutter-3.24.0');
        dir.createSync(recursive: true);
        File('${dir.path}/.stamp').writeAsStringSync('test');
        expect(manager.isVersionCached('3.24.0'), isTrue);
      });
    });

    group('isPlatformCached', () {
      test('returns false when directory does not exist', () {
        expect(
          manager.isPlatformCached('3.24.0', 'android-arm64'),
          isFalse,
        );
      });

      test('returns false when artifacts are missing', () {
        final dir = Directory(
          '${tempDir.path}/flutter-3.24.0/android-arm64',
        );
        dir.createSync(recursive: true);
        // Only create one of two expected files.
        File('${dir.path}/gen_snapshot').writeAsStringSync('bin');
        expect(
          manager.isPlatformCached('3.24.0', 'android-arm64'),
          isFalse,
        );
      });

      test('returns true when all artifacts exist', () {
        final dir = Directory(
          '${tempDir.path}/flutter-3.24.0/android-arm64',
        );
        dir.createSync(recursive: true);
        File('${dir.path}/gen_snapshot').writeAsStringSync('bin');
        File('${dir.path}/libflutter.so').writeAsStringSync('lib');
        expect(
          manager.isPlatformCached('3.24.0', 'android-arm64'),
          isTrue,
        );
      });
    });

    group('listCachedVersions', () {
      test('returns empty list when cache is empty', () {
        expect(manager.listCachedVersions(), isEmpty);
      });

      test('returns versions with stamp files', () {
        for (final ver in ['3.22.0', '3.24.0']) {
          final dir = Directory('${tempDir.path}/flutter-$ver');
          dir.createSync(recursive: true);
          File('${dir.path}/.stamp').writeAsStringSync('test');
        }
        // Create one without stamp.
        Directory('${tempDir.path}/flutter-3.20.0').createSync();

        final versions = manager.listCachedVersions();
        expect(versions, containsAll(['3.22.0', '3.24.0']));
        expect(versions, isNot(contains('3.20.0')));
      });
    });

    group('removeVersion', () {
      test('removes cached version directory', () {
        final dir = Directory('${tempDir.path}/flutter-3.24.0');
        dir.createSync(recursive: true);
        File('${dir.path}/.stamp').writeAsStringSync('test');

        manager.removeVersion('3.24.0');
        expect(dir.existsSync(), isFalse);
      });
    });

    group('cleanupOldVersions', () {
      test('removes all except kept version', () {
        for (final ver in ['3.22.0', '3.24.0', '3.26.0']) {
          final dir = Directory('${tempDir.path}/flutter-$ver');
          dir.createSync(recursive: true);
          File('${dir.path}/.stamp').writeAsStringSync('test');
        }

        manager.cleanupOldVersions(keepVersion: '3.24.0');

        expect(
          Directory('${tempDir.path}/flutter-3.24.0').existsSync(),
          isTrue,
        );
        expect(
          Directory('${tempDir.path}/flutter-3.22.0').existsSync(),
          isFalse,
        );
        expect(
          Directory('${tempDir.path}/flutter-3.26.0').existsSync(),
          isFalse,
        );
      });
    });

    group('genSnapshotPathForPlatform', () {
      test('returns null when file does not exist', () {
        expect(
          manager.genSnapshotPathForPlatform('3.24.0', 'android-arm64'),
          isNull,
        );
      });

      test('returns path when file exists', () {
        final dir = Directory(
          '${tempDir.path}/flutter-3.24.0/android-arm64',
        );
        dir.createSync(recursive: true);
        File('${dir.path}/gen_snapshot').writeAsStringSync('bin');

        expect(
          manager.genSnapshotPathForPlatform('3.24.0', 'android-arm64'),
          endsWith('gen_snapshot'),
        );
      });
    });
  });
}
