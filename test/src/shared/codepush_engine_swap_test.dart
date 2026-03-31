import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  group('CodePushBuildService engine swap', () {
    late MockLogger logger;
    late CodePushBuildService service;
    late Directory tempDir;
    late String originalDir;

    setUp(() {
      logger = MockLogger();
      service = CodePushBuildService(logger: logger);
      tempDir = Directory.systemTemp.createTempSync('engine_swap_test_');
      originalDir = Directory.current.path;
      Directory.current = tempDir;
    });

    tearDown(() {
      Directory.current = originalDir;
      tempDir.deleteSync(recursive: true);
    });

    group('swapAndroidEngine', () {
      test('swaps libflutter.so in stripped_native_libs', () {
        // Create the directory structure.
        final libDir = Directory(
          'build/app/intermediates/stripped_native_libs/release/out/lib/arm64-v8a',
        );
        libDir.createSync(recursive: true);
        File('${libDir.path}/libflutter.so')
            .writeAsStringSync('original-engine');

        // Create the cached replacement.
        final cached = File('${tempDir.path}/cached_libflutter.so');
        cached.writeAsStringSync('code-push-engine');

        final result = service.swapAndroidEngine(cached.path);

        expect(result, isTrue);
        expect(
          File('${libDir.path}/libflutter.so').readAsStringSync(),
          equals('code-push-engine'),
        );
        // Backup should exist.
        expect(
          File('${libDir.path}/libflutter.so.original').existsSync(),
          isTrue,
        );
        expect(
          File('${libDir.path}/libflutter.so.original').readAsStringSync(),
          equals('original-engine'),
        );
      });

      test('swaps libflutter.so in jniLibs', () {
        final libDir = Directory(
          'build/app/intermediates/flutter/release/jniLibs/arm64-v8a',
        );
        libDir.createSync(recursive: true);
        File('${libDir.path}/libflutter.so')
            .writeAsStringSync('original-engine');

        final cached = File('${tempDir.path}/cached_libflutter.so');
        cached.writeAsStringSync('code-push-engine');

        final result = service.swapAndroidEngine(cached.path);

        expect(result, isTrue);
        expect(
          File('${libDir.path}/libflutter.so').readAsStringSync(),
          equals('code-push-engine'),
        );
      });

      test('returns false when no build output found', () {
        final cached = File('${tempDir.path}/cached_libflutter.so');
        cached.writeAsStringSync('code-push-engine');

        final result = service.swapAndroidEngine(cached.path);
        expect(result, isFalse);
      });

      test('does not overwrite existing backup', () {
        final libDir = Directory(
          'build/app/intermediates/stripped_native_libs/release/out/lib/arm64-v8a',
        );
        libDir.createSync(recursive: true);
        File('${libDir.path}/libflutter.so').writeAsStringSync('second-swap');
        File('${libDir.path}/libflutter.so.original')
            .writeAsStringSync('very-first-original');

        final cached = File('${tempDir.path}/cached_libflutter.so');
        cached.writeAsStringSync('code-push-engine');

        service.swapAndroidEngine(cached.path);

        // Original backup should be preserved.
        expect(
          File('${libDir.path}/libflutter.so.original').readAsStringSync(),
          equals('very-first-original'),
        );
      });
    });

    group('swapLinuxEngine', () {
      test('swaps libflutter_linux_gtk.so', () {
        final libDir = Directory('build/linux/x64/release/bundle/lib');
        libDir.createSync(recursive: true);
        File('${libDir.path}/libflutter_linux_gtk.so')
            .writeAsStringSync('original');

        final cached = File('${tempDir.path}/cached_libflutter.so');
        cached.writeAsStringSync('code-push');

        final result = service.swapLinuxEngine(cached.path);

        expect(result, isTrue);
        expect(
          File('${libDir.path}/libflutter_linux_gtk.so').readAsStringSync(),
          equals('code-push'),
        );
      });

      test('returns false when no build output found', () {
        final cached = File('${tempDir.path}/cached_libflutter.so');
        cached.writeAsStringSync('code-push');

        expect(service.swapLinuxEngine(cached.path), isFalse);
      });
    });

    group('swapWindowsEngine', () {
      test('swaps flutter_windows.dll', () {
        final dir = Directory('build/windows/x64/runner/Release');
        dir.createSync(recursive: true);
        File('${dir.path}/flutter_windows.dll').writeAsStringSync('original');

        final cached = File('${tempDir.path}/cached_flutter_engine.dll');
        cached.writeAsStringSync('code-push');

        final result = service.swapWindowsEngine(cached.path);

        expect(result, isTrue);
        expect(
          File('${dir.path}/flutter_windows.dll').readAsStringSync(),
          equals('code-push'),
        );
      });

      test('returns false when no build output found', () {
        final cached = File('${tempDir.path}/cached_flutter_engine.dll');
        cached.writeAsStringSync('code-push');

        expect(service.swapWindowsEngine(cached.path), isFalse);
      });
    });

    group('swapMacosEngine', () {
      test('swaps FlutterMacOS binary', () {
        final dir = Directory(
          'build/macos/Build/Products/Release/Runner.app/Contents/Frameworks/FlutterMacOS.framework/Versions/A',
        );
        dir.createSync(recursive: true);
        File('${dir.path}/FlutterMacOS').writeAsStringSync('original');

        final cached = File('${tempDir.path}/cached_engine.dylib');
        cached.writeAsStringSync('code-push');

        final result = service.swapMacosEngine(cached.path);

        expect(result, isTrue);
        expect(
          File('${dir.path}/FlutterMacOS').readAsStringSync(),
          equals('code-push'),
        );
      });

      test('returns false when no build output found', () {
        final cached = File('${tempDir.path}/cached_engine.dylib');
        cached.writeAsStringSync('code-push');

        expect(service.swapMacosEngine(cached.path), isFalse);
      });
    });
  });
}
