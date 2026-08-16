import 'dart:io';

import 'package:flutter_compile/src/shared/ios_baseline_plist.dart';
import 'package:test/test.dart';

void main() {
  group('resolveIosBaselineId', () {
    test('the id stamped by this run wins over everything', () {
      expect(
        resolveIosBaselineId(
          stampedByBuild: 'stamped',
          explicitFlag: 'flag',
          fromBuiltApp: 'built',
        ),
        'stamped',
      );
    });

    test('the explicit flag wins over the built app', () {
      expect(
        resolveIosBaselineId(explicitFlag: 'flag', fromBuiltApp: 'built'),
        'flag',
      );
    });

    test('the built app is the last resort', () {
      expect(resolveIosBaselineId(fromBuiltApp: 'built'), 'built');
    });

    test('empty strings count as absent', () {
      expect(
        resolveIosBaselineId(
          stampedByBuild: '',
          explicitFlag: '  ',
          fromBuiltApp: 'built',
        ),
        'built',
      );
    });

    test('no source at all resolves to null', () {
      expect(resolveIosBaselineId(), isNull);
    });
  });

  group('restoreIosInfoPlist', () {
    test('round-trips through a temp file with no leftover', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final plist = File('${dir.path}/Info.plist')
        ..writeAsStringSync('stamped');

      restoreIosInfoPlist('original', plistPath: plist.path);

      expect(plist.readAsStringSync(), 'original');
      // The write is temp+rename ON PURPOSE: a bare truncating write
      // could leave an EMPTY plist on a mid-write failure, while the
      // release command's failure guidance says the stamp survives.
      final leftovers = dir
          .listSync()
          .map((e) => e.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('a symlink at the target is REPLACED, not written through', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist3');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final elsewhere = File('${root.path}/elsewhere.txt')
        ..writeAsStringSync('x');
      final plistPath = '${dir.path}/Info.plist';
      Link(plistPath).createSync(elsewhere.path);

      restoreIosInfoPlist('original', plistPath: plistPath);

      // The rename replaces the LINK itself; a bare truncating write
      // would follow it and scribble on the link target instead —
      // the one observable difference between the two mechanisms.
      expect(
        FileSystemEntity.typeSync(plistPath, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(File(plistPath).readAsStringSync(), 'original');
      expect(elsewhere.readAsStringSync(), 'x');
    }, skip: Platform.isWindows ? 'file symlinks need privileges' : false);

    test('a failed restore leaves the target untouched', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist2');
      addTearDown(() => root.deleteSync(recursive: true));
      // The plist's parent does not exist: the temp write throws
      // before anything touches the (also nonexistent) target.
      expect(
        () => restoreIosInfoPlist(
          'original',
          plistPath: '${root.path}/ios/Runner/Info.plist',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        Directory('${root.path}/ios').existsSync(),
        isFalse,
      );
    });
  });

  group('builtIosAppDirFromBinaryPath', () {
    test('derives the app bundle from a baseline binary path', () {
      expect(
        builtIosAppDirFromBinaryPath(
          'build/ios/archive/Runner.xcarchive/Products/Applications/'
          'Runner.app/Frameworks/App.framework/App',
        ),
        'build/ios/archive/Runner.xcarchive/Products/Applications/'
        'Runner.app',
      );
    });

    test('a path outside an app bundle yields no identity source', () {
      expect(builtIosAppDirFromBinaryPath('/tmp/App'), isNull);
      expect(
        builtIosAppDirFromBinaryPath('.dart_tool/flutter_build/x/app.dill'),
        isNull,
      );
    });
  });

  group('readBaselineIdFromBuiltAppPlist', () {
    late Directory tmp;

    const xmlPlist = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleIdentifier</key>
\t<string>com.example.app</string>
\t<key>FCPBaselineId</key>
\t<string>d7eebb10-1234-4abc-9def-0123456789ab</string>
</dict>
</plist>
''';

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fcp_plist_read_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    String writePlist(String content) {
      final app = Directory('${tmp.path}/Runner.app')..createSync();
      File('${app.path}/Info.plist').writeAsStringSync(content);
      return app.path;
    }

    test('reads the stamped id from an XML plist', () {
      final appPath = writePlist(xmlPlist);
      expect(
        readBaselineIdFromBuiltAppPlist(appPath: appPath),
        'd7eebb10-1234-4abc-9def-0123456789ab',
      );
    });

    test('returns null when the built app does not exist', () {
      expect(
        readBaselineIdFromBuiltAppPlist(appPath: '${tmp.path}/nope.app'),
        isNull,
      );
    });

    test('returns null when the key is absent', () {
      final appPath = writePlist(
        xmlPlist.replaceAll('FCPBaselineId', 'SomethingElse'),
      );
      expect(readBaselineIdFromBuiltAppPlist(appPath: appPath), isNull);
    });

    test(
      'reads the stamped id from a BINARY plist (the Xcode-built shape)',
      () {
        final appPath = writePlist(xmlPlist);
        final convert = Process.runSync(
          'plutil',
          ['-convert', 'binary1', '$appPath/Info.plist'],
        );
        expect(convert.exitCode, 0, reason: 'plutil must convert');
        expect(
          readBaselineIdFromBuiltAppPlist(appPath: appPath),
          'd7eebb10-1234-4abc-9def-0123456789ab',
        );
      },
      skip: !Platform.isMacOS ? 'plutil is macOS-only' : null,
    );
  });
}
