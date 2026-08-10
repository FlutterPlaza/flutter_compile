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

    group('android engine cache (finding #2)', () {
      test('androidEngineDir points at the finalize read path', () {
        expect(
          manager.androidEngineDir('3.41.6'),
          equals('${tempDir.path}/flutter-3.41.6/android-arm64'),
        );
      });

      test('isAndroidEngineCached is false when the engine is absent', () {
        expect(manager.isAndroidEngineCached('3.41.6'), isFalse);
      });

      test('isAndroidEngineCached needs BOTH libflutter.so and gen_snapshot',
          () {
        final dir = Directory(manager.androidEngineDir('3.41.6'))
          ..createSync(recursive: true);
        File('${dir.path}/libflutter.so').writeAsBytesSync([1, 2, 3]);
        // Only one of the two present → not cached.
        expect(manager.isAndroidEngineCached('3.41.6'), isFalse);
        File('${dir.path}/gen_snapshot').writeAsBytesSync([4, 5, 6]);
        expect(manager.isAndroidEngineCached('3.41.6'), isTrue);
      });

      test(
          'ensureAndroidEngine short-circuits when already cached '
          '(no tool download)', () async {
        final dir = Directory(manager.androidEngineDir('3.41.6'))
          ..createSync(recursive: true);
        File('${dir.path}/libflutter.so').writeAsBytesSync([1]);
        File('${dir.path}/gen_snapshot').writeAsBytesSync([2]);
        // Cached + not forced → returns true without touching the network.
        expect(
          await manager.ensureAndroidEngine(flutterVersion: '3.41.6'),
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

    group('currentPlatform', () {
      test('has os-arch shape', () {
        expect(manager.currentPlatform, matches(RegExp(r'^[a-z]+-[a-z0-9]+$')));
      });
    });
  });
}
