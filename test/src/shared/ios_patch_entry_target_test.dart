import 'dart:io';

import 'package:flutter_compile/src/shared/ios_patch_entry_target.dart';
import 'package:test/test.dart';

void main() {
  group('ios_patch_entry_target', () {
    late Directory tempDir;

    // All paths are anchored on the temp dir explicitly: mutating the
    // process-global Directory.current is a chdir(2) that races the
    // other concurrently-running test isolates.
    String p(String rel) => '${tempDir.path}/$rel';
    String libDir() => p('lib');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fcp_ios_patch_entry_');
      Directory(p('lib/screens')).createSync(recursive: true);
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('findCodePushPatchSourceCandidates returns matching lib files', () {
      File(p('lib/screens/home_screen.dart')).writeAsStringSync('''
Object? codePushPatch() => const <String, Object?>{'ok': true};
''');

      expect(
        findCodePushPatchSourceCandidates(libDirPath: libDir()),
        equals(['lib/screens/home_screen.dart']),
      );
    });

    test('findCodePushPatchSourceCandidates ignores generated entry file', () {
      File(p('lib/$kGeneratedIosPatchEntryFilename')).writeAsStringSync('''
Object? codePushPatch() => null;
''');
      File(p('lib/screens/home_screen.dart')).writeAsStringSync('''
Object? codePushPatch() => 1;
''');

      expect(
        findCodePushPatchSourceCandidates(libDirPath: libDir()),
        equals(['lib/screens/home_screen.dart']),
      );
    });

    test('findCodePushPatchSourceCandidates ignores invocation-only wrappers',
        () {
      File(p('lib/code_push_local_patch.dart')).writeAsStringSync('''
import 'screens/home_screen.dart';

@pragma('dyn-module:entry-point')
Object? main() => codePushPatch();
''');
      File(p('lib/screens/home_screen.dart')).writeAsStringSync('''
Object? codePushPatch() => 1;
''');

      expect(
        findCodePushPatchSourceCandidates(libDirPath: libDir()),
        equals(['lib/screens/home_screen.dart']),
      );
    });

    test('findCodePushPatchSourceCandidates returns sorted matches', () {
      File(p('lib/b.dart')).writeAsStringSync('Object? codePushPatch() => 1;');
      File(p('lib/a.dart')).writeAsStringSync('Object? codePushPatch() => 2;');

      expect(
        findCodePushPatchSourceCandidates(libDirPath: libDir()),
        equals(['lib/a.dart', 'lib/b.dart']),
      );
    });

    test('importPathForPatchSource returns lib-relative import path', () {
      final file = File(p('lib/screens/home_screen.dart'))
        ..writeAsStringSync('Object? codePushPatch() => null;');

      expect(
        importPathForPatchSource(file.path, libDirPath: libDir()),
        equals('screens/home_screen.dart'),
      );
      expect(
        importPathForPatchSource(file.absolute.path, libDirPath: libDir()),
        equals('screens/home_screen.dart'),
      );
    });

    test('importPathForPatchSource rejects files outside lib', () {
      final file = File(p('tool/patch.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('Object? codePushPatch() => null;');

      expect(importPathForPatchSource(file.path, libDirPath: libDir()), isNull);
    });

    test('buildGeneratedIosPatchEntrypoint wraps codePushPatch in main', () {
      final source = buildGeneratedIosPatchEntrypoint(
        importPath: 'screens/home_screen.dart',
      );

      expect(source, contains("import 'screens/home_screen.dart';"));
      expect(source, contains("@pragma('dyn-module:entry-point')"));
      expect(source, contains('Object? main() => codePushPatch();'));
    });
  });
}
