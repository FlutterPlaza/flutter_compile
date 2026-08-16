import 'dart:io';

import 'package:flutter_compile/src/shared/atomic_file_write.dart';
import 'package:test/test.dart';

void main() {
  group('atomicReplaceFileContents', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fcp_writer');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('replaces content and leaves no temp behind', () {
      final target = File('${root.path}/config.yaml')..writeAsStringSync('old');

      atomicReplaceFileContents(target.path, 'new');

      expect(target.readAsStringSync(), 'new');
      final leftovers = root
          .listSync()
          .map((e) => e.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test(
        'a failed RENAME discards the temp and rethrows — the one '
        'property nothing else pinned', () {
      // A non-empty directory at the target path: the temp write
      // succeeds beside it, the rename onto it throws, and the
      // cleanup-then-rethrow branch must run — without it a failed
      // rename parks a dot-temp in the target's (tracked) directory.
      final blocker = Directory('${root.path}/config.yaml')..createSync();
      File('${blocker.path}/occupant.txt').writeAsStringSync('x');

      expect(
        () => atomicReplaceFileContents(blocker.path, 'new'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        File('${blocker.path}/occupant.txt').readAsStringSync(),
        'x',
      );
      final leftovers = root
          .listSync()
          .map((e) => e.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('an ABSENT target is recreated (documented mode exception)', () {
      // No mode to preserve: the file lands at the umask default —
      // property 3's one documented exception.
      final path = '${root.path}/recreated.yaml';

      atomicReplaceFileContents(path, 'content');

      expect(File(path).readAsStringSync(), 'content');
    });
  });
}
