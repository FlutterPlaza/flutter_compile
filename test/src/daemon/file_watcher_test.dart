import 'dart:async';
import 'dart:io';

import 'package:flutter_compile/src/daemon/file_watcher.dart';
import 'package:test/test.dart';

void main() {
  group('FileWatcher', () {
    late Directory tempDir;
    late File watchedFile;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fw_test_');
      watchedFile = File('${tempDir.path}/test_file');
      watchedFile.writeAsStringSync('initial');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('fires callback when watched file changes', () async {
      final completer = Completer<String>();
      final watcher = FileWatcher(
        paths: [watchedFile.path],
        onChanged: (path) {
          if (!completer.isCompleted) completer.complete(path);
        },
      );
      watcher.start();

      // Allow watchers to settle
      await Future<void>.delayed(const Duration(milliseconds: 100));

      watchedFile.writeAsStringSync('changed');

      final result = await completer.future.timeout(
        const Duration(seconds: 15),
      );
      expect(result, equals(watchedFile.path));

      watcher.stop();
    });

    test('debounces rapid writes to a single callback', () async {
      var callCount = 0;
      final watcher = FileWatcher(
        paths: [watchedFile.path],
        onChanged: (_) => callCount++,
      );
      watcher.start();

      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Write rapidly
      for (var i = 0; i < 5; i++) {
        watchedFile.writeAsStringSync('change $i');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      // Wait for debounce to fire (500ms + generous margin for Windows)
      await Future<void>.delayed(const Duration(seconds: 3));

      // Should have been debounced to 1-2 calls, not 5
      expect(callCount, lessThanOrEqualTo(2));
      expect(callCount, greaterThan(0));

      watcher.stop();
    });

    test('stop cancels all subscriptions', () async {
      var callCount = 0;
      final watcher = FileWatcher(
        paths: [watchedFile.path],
        onChanged: (_) => callCount++,
      );
      watcher.start();
      watcher.stop();

      await Future<void>.delayed(const Duration(milliseconds: 100));
      watchedFile.writeAsStringSync('after stop');
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(callCount, equals(0));
    });
  });
}
