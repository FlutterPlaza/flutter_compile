import 'dart:io';

import 'package:flutter_compile/src/shared/ios_baseline_plist.dart';
import 'package:test/test.dart';

void main() {
  group('generateBaselineId', () {
    test('returns a UUID v4 string', () {
      final baselineId = generateBaselineId();
      expect(
        baselineId,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )),
      );
    });

    test('returns different values across calls', () {
      expect(generateBaselineId(), isNot(equals(generateBaselineId())));
    });
  });

  group('iOS Info.plist helpers', () {
    late Directory tempDir;
    late String plistPath;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('fcp-plist-test-');
      plistPath = '${tempDir.path}/Info.plist';
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('inserts into the OUTER dict when nested dicts are present', () {
      const baselineId = '12345678-1234-4234-8234-123456789abc';
      File(plistPath).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleName</key>
\t<string>Runner</string>
\t<key>NSAppTransportSecurity</key>
\t<dict>
\t\t<key>NSAllowsArbitraryLoads</key>
\t\t<true/>
\t</dict>
\t<key>UILaunchStoryboardName</key>
\t<string>LaunchScreen</string>
</dict>
</plist>
''');

      writeBaselineIdToIosInfoPlist(baselineId, plistPath: plistPath);

      final content = File(plistPath).readAsStringSync();
      final keyIndex = content.indexOf('<key>FCPBaselineId</key>');
      final nestedDictClose = content.indexOf('</dict>');
      expect(keyIndex, greaterThan(nestedDictClose),
          reason: 'FCPBaselineId must land after the nested dict closes, '
              'inside the outer dict');
      expect(content.lastIndexOf('</dict>'), greaterThan(keyIndex),
          reason: 'FCPBaselineId must sit before the outer dict closes');
    });

    test('returns null when plist does not exist', () {
      expect(
        writeBaselineIdToIosInfoPlist(
          '12345678-1234-4234-8234-123456789abc',
          plistPath: plistPath,
        ),
        isNull,
      );
    });

    test('inserts a new FCPBaselineId key and can restore original content',
        () {
      const originalContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>CFBundleName</key>
\t<string>Runner</string>
</dict>
</plist>
''';
      File(plistPath).writeAsStringSync(originalContent);

      final original = writeBaselineIdToIosInfoPlist(
        '12345678-1234-4234-8234-123456789abc',
        plistPath: plistPath,
      );

      expect(original, originalContent);
      final updated = File(plistPath).readAsStringSync();
      expect(updated, contains('<key>FCPBaselineId</key>'));
      expect(
        updated,
        contains('<string>12345678-1234-4234-8234-123456789abc</string>'),
      );

      restoreIosInfoPlist(original!, plistPath: plistPath);
      expect(File(plistPath).readAsStringSync(), originalContent);
    });

    test('replaces an existing FCPBaselineId value', () {
      const originalContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
\t<key>FCPBaselineId</key>
\t<string>old-value</string>
</dict>
</plist>
''';
      File(plistPath).writeAsStringSync(originalContent);

      writeBaselineIdToIosInfoPlist(
        '12345678-1234-4234-8234-123456789abc',
        plistPath: plistPath,
      );

      final updated = File(plistPath).readAsStringSync();
      expect(updated, isNot(contains('<string>old-value</string>')));
      expect(
        updated,
        contains('<string>12345678-1234-4234-8234-123456789abc</string>'),
      );
    });
  });
}
