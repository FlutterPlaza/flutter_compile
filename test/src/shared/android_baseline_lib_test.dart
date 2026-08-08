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
    late Directory oldCwd;

    const strippedRoot = 'build/app/intermediates/stripped_native_libs/release';

    void createLib(String relativePath) {
      File(relativePath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
    }

    setUp(() {
      service = CodePushBuildService(logger: MockLogger());
      oldCwd = Directory.current;
      tmp = Directory.systemTemp.createTempSync('fcp_baseline_lib_test');
      Directory.current = tmp;
    });

    tearDown(() {
      Directory.current = oldCwd;
      tmp.deleteSync(recursive: true);
    });

    test('returns null when no release build output exists', () {
      expect(service.findAndroidBaselineLibPath(), isNull);
    });

    test('finds the AGP 8 stripped layout', () {
      createLib(
        '$strippedRoot/stripReleaseDebugSymbols/out/lib/arm64-v8a/libapp.so',
      );
      expect(
        service.findAndroidBaselineLibPath(),
        '$strippedRoot/stripReleaseDebugSymbols/out/lib/arm64-v8a/libapp.so',
      );
    });

    test('finds the legacy stripped layout', () {
      createLib('$strippedRoot/out/lib/arm64-v8a/libapp.so');
      expect(
        service.findAndroidBaselineLibPath(),
        '$strippedRoot/out/lib/arm64-v8a/libapp.so',
      );
    });

    test('prefers arm64-v8a over armeabi-v7a', () {
      createLib('$strippedRoot/out/lib/armeabi-v7a/libapp.so');
      createLib('$strippedRoot/out/lib/arm64-v8a/libapp.so');
      expect(
        service.findAndroidBaselineLibPath(),
        '$strippedRoot/out/lib/arm64-v8a/libapp.so',
      );
    });

    test('falls back to armeabi-v7a when it is the only packaged ABI', () {
      createLib('$strippedRoot/out/lib/armeabi-v7a/libapp.so');
      expect(
        service.findAndroidBaselineLibPath(),
        '$strippedRoot/out/lib/armeabi-v7a/libapp.so',
      );
    });

    test('discovers an unknown stripped layout by scanning', () {
      createLib('$strippedRoot/someFutureTaskName/out/lib/arm64-v8a/libapp.so');
      expect(service.findAndroidBaselineLibPath(), endsWith('libapp.so'));
      expect(service.findAndroidBaselineLibPath(), contains('arm64-v8a'));
    });

    test('scan tiebreak: the newest of several copies wins', () {
      createLib('$strippedRoot/oldTask/out/lib/arm64-v8a/libapp.so');
      createLib('$strippedRoot/newTask/out/lib/arm64-v8a/libapp.so');
      final old = File('$strippedRoot/oldTask/out/lib/arm64-v8a/libapp.so');
      old.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(
        service.findAndroidBaselineLibPath(),
        contains('newTask'),
      );
    });

    test('never returns a pre-strip copy', () {
      createLib(
        'build/app/intermediates/merged_native_libs/release/out/lib/'
        'arm64-v8a/libapp.so',
      );
      createLib('build/app/intermediates/flutter/release/arm64-v8a/app.so');
      expect(service.findAndroidBaselineLibPath(), isNull);
    });
  });
}
