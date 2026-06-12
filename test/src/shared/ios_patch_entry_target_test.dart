import 'dart:io';

import 'package:flutter_compile/src/shared/ios_patch_entry_target.dart';
import 'package:test/test.dart';

void main() {
  group('ios_patch_entry_target', () {
    late Directory tempDir;
    late Directory previous;

    setUp(() {
      previous = Directory.current;
      tempDir = Directory.systemTemp.createTempSync('fcp_ios_patch_entry_');
      Directory.current = tempDir;
      Directory('lib/screens').createSync(recursive: true);
    });

    tearDown(() {
      Directory.current = previous;
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('findCodePushPatchSourceCandidates returns matching lib files', () {
      File('lib/screens/home_screen.dart').writeAsStringSync('''
Object? codePushPatch() => const <String, Object?>{'ok': true};
''');

      expect(
        findCodePushPatchSourceCandidates(),
        equals(['lib/screens/home_screen.dart']),
      );
    });

    test('findCodePushPatchSourceCandidates ignores generated entry file', () {
      File('lib/$kGeneratedIosPatchEntryFilename').writeAsStringSync('''
Object? codePushPatch() => null;
''');
      File('lib/screens/home_screen.dart').writeAsStringSync('''
Object? codePushPatch() => 1;
''');

      expect(
        findCodePushPatchSourceCandidates(),
        equals(['lib/screens/home_screen.dart']),
      );
    });

    test('findCodePushPatchSourceCandidates ignores invocation-only wrappers',
        () {
      File('lib/code_push_local_patch.dart').writeAsStringSync('''
import 'screens/home_screen.dart';

@pragma('dyn-module:entry-point')
Object? main() => codePushPatch();
''');
      File('lib/screens/home_screen.dart').writeAsStringSync('''
Object? codePushPatch() => 1;
''');

      expect(
        findCodePushPatchSourceCandidates(),
        equals(['lib/screens/home_screen.dart']),
      );
    });

    test('findCodePushPatchSourceCandidates returns sorted matches', () {
      File('lib/b.dart').writeAsStringSync('Object? codePushPatch() => 1;');
      File('lib/a.dart').writeAsStringSync('Object? codePushPatch() => 2;');

      expect(
        findCodePushPatchSourceCandidates(),
        equals(['lib/a.dart', 'lib/b.dart']),
      );
    });

    test('importPathForPatchSource returns lib-relative import path', () {
      final file = File('lib/screens/home_screen.dart')
        ..writeAsStringSync('Object? codePushPatch() => null;');

      expect(
        importPathForPatchSource(file.path),
        equals('screens/home_screen.dart'),
      );
      expect(
        importPathForPatchSource(file.absolute.path),
        equals('screens/home_screen.dart'),
      );
    });

    test('importPathForPatchSource rejects files outside lib', () {
      final file = File('tool/patch.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('Object? codePushPatch() => null;');

      expect(importPathForPatchSource(file.path), isNull);
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
