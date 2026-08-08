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

    test('a commented-out permission does not count as present', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <!-- $permission -->\n'
          '    <application/>\n'
          '</manifest>\n';
      final result = ensureInternetPermission(manifest);
      // The real (uncommented) declaration must have been inserted.
      final uncommented = result.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
      expect(uncommented, contains(permission));
    });
  });

  manifestStates();
}

const _permission =
    '<uses-permission android:name="android.permission.INTERNET"/>';

/// The three manifest states `fcp codepush init` can encounter, verified
/// through the pure write decision (`computeManifestUpdate`) that drives
/// every manifest write in `_setupAndroid`.
void manifestStates() {
  group('computeManifestUpdate', () {
    test('fresh scaffold: inserts INTERNET and wires CodePushApp', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <application\n'
          '        android:label="myapp"\n'
          '        android:name="\${applicationName}"\n'
          '        android:icon="@mipmap/ic_launcher">\n'
          '    </application>\n'
          '</manifest>\n';
      final result = computeManifestUpdate(manifest);
      expect(result, isNotNull);
      expect(result, contains(_permission));
      expect(result, contains('android:name=".CodePushApp"'));
      expect(result, isNot(contains(r'${applicationName}')));
    });

    test('custom Application class: inserts INTERNET, leaves the class alone',
        () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <application\n'
          '        android:name="com.example.MyApplication"\n'
          '        android:label="myapp">\n'
          '    </application>\n'
          '</manifest>\n';
      final result = computeManifestUpdate(manifest);
      expect(result, isNotNull);
      expect(result, contains(_permission));
      expect(result, contains('android:name="com.example.MyApplication"'));
      expect(result, isNot(contains('CodePushApp')));
    });

    test('custom Application class with INTERNET present: no write', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    $_permission\n'
          '    <application android:name="com.example.MyApplication">\n'
          '    </application>\n'
          '</manifest>\n';
      expect(computeManifestUpdate(manifest), isNull);
    });

    test('re-run (CodePushApp wired, INTERNET present): no write', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    $_permission\n'
          '    <application android:name=".CodePushApp">\n'
          '    </application>\n'
          '</manifest>\n';
      expect(computeManifestUpdate(manifest), isNull);
    });

    test('re-run with INTERNET missing: restores only the permission', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <application android:name=".CodePushApp">\n'
          '    </application>\n'
          '</manifest>\n';
      final result = computeManifestUpdate(manifest);
      expect(result, isNotNull);
      expect(result, contains(_permission));
      // Idempotent from here: a second pass writes nothing.
      expect(computeManifestUpdate(result!), isNull);
    });
  });

  group('findApplicationClassName', () {
    test('reads the class from the application element, not a permission', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <uses-permission android:name="android.permission.CAMERA"/>\n'
          '    <application\n'
          '        android:name="com.example.MyApplication">\n'
          '    </application>\n'
          '</manifest>\n';
      expect(
        findApplicationClassName(manifest),
        equals('com.example.MyApplication'),
      );
    });

    test('returns null when the application element has no android:name', () {
      const manifest =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <uses-permission android:name="android.permission.CAMERA"/>\n'
          '    <application android:label="myapp">\n'
          '    </application>\n'
          '</manifest>\n';
      expect(findApplicationClassName(manifest), isNull);
    });
  });
}
