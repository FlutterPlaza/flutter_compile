import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('android_engine_verify');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String writeArchive(String name, Map<String, List<int>> entries) {
    final archive = Archive();
    entries.forEach((path, bytes) {
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    final file = File('${tmp.path}/$name')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return file.path;
  }

  final engineBytes = List<int>.generate(128, (i) => (i * 3) % 256);
  final engineSha = sha256.convert(engineBytes).toString();

  test('accepts an APK whose engine matches the expected checksum', () {
    final apk = writeArchive('app-release.apk', {
      'lib/arm64-v8a/libflutter.so': engineBytes,
      'lib/arm64-v8a/libapp.so': [1, 2, 3],
    });
    expect(
      CodePushBuildService.androidArchiveContainsEngine(
        archivePath: apk,
        expectedSha256: engineSha,
      ),
      isTrue,
    );
  });

  test('accepts an AAB layout (base/lib/... prefix)', () {
    final aab = writeArchive('app-release.aab', {
      'base/lib/arm64-v8a/libflutter.so': engineBytes,
    });
    expect(
      CodePushBuildService.androidArchiveContainsEngine(
        archivePath: aab,
        expectedSha256: engineSha,
      ),
      isTrue,
    );
  });

  test('rejects an artifact carrying a different engine', () {
    final apk = writeArchive('app-release.apk', {
      'lib/arm64-v8a/libflutter.so': [9, 9, 9, 9],
    });
    expect(
      CodePushBuildService.androidArchiveContainsEngine(
        archivePath: apk,
        expectedSha256: engineSha,
      ),
      isFalse,
    );
  });

  test('rejects an artifact with no arm64 engine at all', () {
    final apk = writeArchive('app-release.apk', {
      'lib/armeabi-v7a/libflutter.so': engineBytes,
    });
    expect(
      CodePushBuildService.androidArchiveContainsEngine(
        archivePath: apk,
        expectedSha256: engineSha,
      ),
      isFalse,
    );
  });

  test('rejects an unreadable or non-zip file without throwing', () {
    final bogus = File('${tmp.path}/not-a-zip.apk')
      ..writeAsStringSync('definitely not a zip');
    expect(
      CodePushBuildService.androidArchiveContainsEngine(
        archivePath: bogus.path,
        expectedSha256: engineSha,
      ),
      isFalse,
    );
  });
}
