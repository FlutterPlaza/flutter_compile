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
        'a writable file inside a read-only directory throws and the '
        'target stays byte-identical — the documented COST', () {
      // The one genuine breaking change vs the in-place writers: the
      // temp+rename shape needs w+x on the DIRECTORY. This row is
      // what keeps a future revert to in-place-on-EACCES (which would
      // reopen the truncate-on-ENOSPC hole) from shipping green.
      // (Assumes a non-root test process; root writes through 0555.)
      final dir = Directory('${root.path}/Runner')..createSync();
      final target = File('${dir.path}/Info.plist')
        ..writeAsStringSync('original');
      Process.runSync('chmod', ['555', dir.path]);
      addTearDown(() => Process.runSync('chmod', ['755', dir.path]));

      expect(
        () => atomicReplaceFileContents(target.path, 'replaced'),
        throwsA(isA<FileSystemException>()),
      );

      Process.runSync('chmod', ['755', dir.path]);
      expect(target.readAsStringSync(), 'original');
      final leftovers = dir
          .listSync()
          .map((e) => e.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    },
        skip: Platform.isWindows
            ? 'POSIX directory-permission semantics'
            : false);

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

    test(
        'a NON-600 target mode survives — pins the faithful-mode '
        'chmod, not just the owner-only clamp', () {
      // The plist-level row uses a 0600 target, which is exactly the
      // pre-content clamp value: delete the faithful-mode chmod and
      // that row stays green while every 0644 target silently becomes
      // 0600. A 0640 target isolates the faithful chmod itself; both
      // platform writers inherit this via the shared helper.
      final target = File('${root.path}/config.yaml')..writeAsStringSync('old');
      Process.runSync('chmod', ['640', target.path]);

      atomicReplaceFileContents(target.path, 'new');

      expect(target.statSync().mode & 0xFFF, int.parse('640', radix: 8));
      expect(target.readAsStringSync(), 'new');
    }, skip: Platform.isWindows ? 'POSIX mode bits' : false);

    test(
        'a READ-ONLY (0444) target still restores — content lands '
        'before the faithful-mode clamp', () {
      // Exercises the documented ordering: the content is written
      // while the temp is still owner-writable, and only then is the
      // faithful (here: unwritable) mode applied. Reversed ordering
      // would try to write into a 0444 temp and fail.
      final target = File('${root.path}/config.yaml')..writeAsStringSync('old');
      Process.runSync('chmod', ['444', target.path]);
      addTearDown(() => Process.runSync('chmod', ['644', target.path]));

      atomicReplaceFileContents(target.path, 'new');

      expect(target.statSync().mode & 0xFFF, int.parse('444', radix: 8));
      expect(target.readAsStringSync(), 'new');
    }, skip: Platform.isWindows ? 'POSIX mode bits' : false);

    test('an ABSENT target is recreated (documented mode exception)', () {
      // No mode to preserve: the file lands at the umask default —
      // property 3's one documented exception.
      final path = '${root.path}/recreated.yaml';

      atomicReplaceFileContents(path, 'content');

      expect(File(path).readAsStringSync(), 'content');
    });
  });
}
