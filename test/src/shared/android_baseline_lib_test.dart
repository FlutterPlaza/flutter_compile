import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  group('findAndroidBaselineLibPath', () {
    late CodePushBuildService service;
    late Directory tmp;

    const strippedRoot = 'build/app/intermediates/stripped_native_libs/release';

    // All paths are anchored on the temp dir explicitly: mutating the
    // process-global Directory.current is a chdir(2) that races the
    // other concurrently-running test isolates.
    String p(String rel) => '${tmp.path}/$rel';
    String? find() => service.findAndroidBaselineLibPath(projectRoot: tmp.path);

    void createLib(String relativePath) {
      File(p(relativePath))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
    }

    setUp(() {
      service = CodePushBuildService(logger: MockLogger());
      tmp = Directory.systemTemp.createTempSync('fcp_baseline_lib_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns null when no release build output exists', () {
      expect(find(), isNull);
    });

    test('finds the AGP 8 stripped layout', () {
      createLib(
        '$strippedRoot/stripReleaseDebugSymbols/out/lib/arm64-v8a/libapp.so',
      );
      expect(
        find(),
        p('$strippedRoot/stripReleaseDebugSymbols/out/lib/arm64-v8a/libapp.so'),
      );
    });

    test('finds the legacy stripped layout', () {
      createLib('$strippedRoot/out/lib/arm64-v8a/libapp.so');
      expect(find(), p('$strippedRoot/out/lib/arm64-v8a/libapp.so'));
    });

    test('prefers arm64-v8a over armeabi-v7a', () {
      createLib('$strippedRoot/out/lib/armeabi-v7a/libapp.so');
      createLib('$strippedRoot/out/lib/arm64-v8a/libapp.so');
      expect(find(), p('$strippedRoot/out/lib/arm64-v8a/libapp.so'));
    });

    test('falls back to armeabi-v7a when it is the only packaged ABI', () {
      createLib('$strippedRoot/out/lib/armeabi-v7a/libapp.so');
      expect(find(), p('$strippedRoot/out/lib/armeabi-v7a/libapp.so'));
    });

    test('discovers an unknown stripped layout by scanning', () {
      createLib('$strippedRoot/someFutureTaskName/out/lib/arm64-v8a/libapp.so');
      expect(find(), endsWith('libapp.so'));
      expect(find(), contains('arm64-v8a'));
    });

    test('scan tiebreak: the newest of several copies wins', () {
      createLib('$strippedRoot/oldTask/out/lib/arm64-v8a/libapp.so');
      createLib('$strippedRoot/newTask/out/lib/arm64-v8a/libapp.so');
      final old = File(p('$strippedRoot/oldTask/out/lib/arm64-v8a/libapp.so'));
      old.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(find(), contains('newTask'));
    });

    test('never returns a pre-strip copy', () {
      createLib(
        'build/app/intermediates/merged_native_libs/release/out/lib/'
        'arm64-v8a/libapp.so',
      );
      createLib('build/app/intermediates/flutter/release/arm64-v8a/app.so');
      expect(find(), isNull);
    });
  });
}
