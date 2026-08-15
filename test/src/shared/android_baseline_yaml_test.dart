import 'dart:io';

import 'package:flutter_compile/src/shared/android_baseline_yaml.dart';
import 'package:test/test.dart';

void main() {
  group('writeReleaseVersionToAndroidYaml', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('ab_yaml_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    String nestedYamlPath() {
      // Forward-slash joins on purpose, mirroring the shape of
      // kDefaultAndroidCodePushYamlPath: the temp-name computation
      // must split on BOTH separators, or on Windows the basename
      // comes back as the whole path and the write lands in a
      // directory that does not exist.
      final nested = Directory('${tempDir.path}/android/app/src/main/assets')
        ..createSync(recursive: true);
      return '${nested.path}/codepush.yaml';
    }

    test('writes through a nested forward-slash path, no leftover temp', () {
      final yamlPath = nestedYamlPath();
      File(yamlPath).writeAsStringSync('app_id: "a"\n');

      final original = writeReleaseVersionToAndroidYaml(
        '1.2.3+4',
        yamlPath: yamlPath,
      );

      expect(original, 'app_id: "a"\n');
      expect(
        File(yamlPath).readAsStringSync(),
        'app_id: "a"\nrelease_version: "1.2.3+4"\n',
      );
      // The temp must be renamed away on success — anything left
      // matching it would ship in the APK were it not dot-prefixed,
      // and even dot-prefixed it must not accumulate.
      final leftovers = File(yamlPath)
          .parent
          .listSync()
          .map((e) => e.path)
          .where((p) => p.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('replaces an existing release_version line in place', () {
      final yamlPath = nestedYamlPath();
      File(yamlPath).writeAsStringSync(
        'app_id: "a"\nrelease_version: "old"\nserver: "s"\n',
      );

      writeReleaseVersionToAndroidYaml('2.0.0+7', yamlPath: yamlPath);

      expect(
        File(yamlPath).readAsStringSync(),
        'app_id: "a"\nrelease_version: "2.0.0+7"\nserver: "s"\n',
      );
    });

    test('a missing yaml file returns null and writes nothing', () {
      final yamlPath = '${tempDir.path}/does/not/exist/codepush.yaml';
      expect(
        writeReleaseVersionToAndroidYaml('1.0.0', yamlPath: yamlPath),
        isNull,
      );
      expect(File(yamlPath).existsSync(), isFalse);
    });

    test('restoreAndroidYaml round-trips the original content', () {
      final yamlPath = nestedYamlPath();
      File(yamlPath).writeAsStringSync('release_version: "old"\n');

      final original =
          writeReleaseVersionToAndroidYaml('2.0.0', yamlPath: yamlPath)!;
      restoreAndroidYaml(original, yamlPath: yamlPath);

      expect(File(yamlPath).readAsStringSync(), 'release_version: "old"\n');
    });

    test('an unstampable version throws before touching the file', () {
      final yamlPath = nestedYamlPath();
      File(yamlPath).writeAsStringSync('app_id: "a"\n');

      expect(
        () =>
            writeReleaseVersionToAndroidYaml('1.0"\nboom', yamlPath: yamlPath),
        throwsArgumentError,
      );
      expect(File(yamlPath).readAsStringSync(), 'app_id: "a"\n');
    });
  });
}
