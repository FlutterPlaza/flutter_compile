import 'package:flutter_compile/src/commands/codepush_commands/_codepush_init.dart';
import 'package:test/test.dart';

void main() {
  group('ensureInternetPermission', () {
    const permission =
        '<uses-permission android:name="android.permission.INTERNET"/>';

    test('inserts the permission after the opening manifest tag when absent',
        () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <application android:name="\${applicationName}">\n'
          '    </application>\n'
          '</manifest>\n';
      final result = ensureInternetPermission(manifest);
      expect(result, contains(permission));
      // Inserted inside <manifest>, before <application>.
      expect(
          result.indexOf(permission), greaterThan(result.indexOf('<manifest')));
      expect(
          result.indexOf(permission), lessThan(result.indexOf('<application')));
    });

    test('is a no-op when the permission is already present', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    $permission\n'
          '    <application/>\n'
          '</manifest>\n';
      expect(ensureInternetPermission(manifest), equals(manifest));
    });

    test('does not duplicate on a second pass (idempotent)', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <application/>\n'
          '</manifest>\n';
      final once = ensureInternetPermission(manifest);
      final twice = ensureInternetPermission(once);
      expect(twice, equals(once));
      expect(permission.allMatches(once).length, equals(1));
    });

    test('returns the manifest unchanged when there is no <manifest> tag', () {
      const junk = 'not a manifest';
      expect(ensureInternetPermission(junk), equals(junk));
    });
  });
}
