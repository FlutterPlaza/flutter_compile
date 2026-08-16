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

    test('writes THROUGH a symlinked plist, preserving the link', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist3');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final target = File('${root.path}/shared/Info.plist')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('stamped');
      final plistPath = '${dir.path}/Info.plist';
      Link(plistPath).createSync(target.path);

      restoreIosInfoPlist('original', plistPath: plistPath);

      // The write resolves the link and renames AT THE TARGET: a
      // rename at the spelled path would replace the link itself
      // and strand the content in the old target — one
      // release --build on a shared-config monorepo checkout would
      // destroy the wiring.
      expect(
        FileSystemEntity.typeSync(plistPath, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(target.readAsStringSync(), 'original');
    }, skip: Platform.isWindows ? 'file symlinks need privileges' : false);

    test('stamp + restore round-trip through a link leaves the repo clean', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist4');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      const original = '<dict>\n</dict>\n';
      final target = File('${root.path}/shared/Info.plist')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(original);
      final plistPath = '${dir.path}/Info.plist';
      Link(plistPath).createSync(target.path);

      final saved = writeBaselineIdToIosInfoPlist('u-1', plistPath: plistPath)!;
      expect(target.readAsStringSync(), contains('FCPBaselineId'));
      expect(
        FileSystemEntity.typeSync(plistPath, followLinks: false),
        FileSystemEntityType.link,
      );

      restoreIosInfoPlist(saved, plistPath: plistPath);

      expect(target.readAsStringSync(), original);
      expect(
        FileSystemEntity.typeSync(plistPath, followLinks: false),
        FileSystemEntityType.link,
      );
      final leftovers = [
        ...Directory('${root.path}/shared').listSync(),
        ...dir.listSync(),
      ].map((e) => e.path).where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    }, skip: Platform.isWindows ? 'file symlinks need privileges' : false);

    test(
        'a DANGLING link is the documented exception: replaced by a '
        'real file carrying the content', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist6');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final plistPath = '${dir.path}/Info.plist';
      Link(plistPath).createSync('${root.path}/gone/Info.plist');

      restoreIosInfoPlist('original', plistPath: plistPath);

      // It points at nothing, so there is nothing to preserve — the
      // helper's comment makes exactly this claim; this row keeps
      // the claim honest.
      expect(
        FileSystemEntity.typeSync(plistPath, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(File(plistPath).readAsStringSync(), 'original');
    }, skip: Platform.isWindows ? 'file symlinks need privileges' : false);

    test('the target mode survives the cycle', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist7');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final plist = File('${dir.path}/Info.plist')
        ..writeAsStringSync('stamped');
      Process.runSync('chmod', ['600', plist.path]);

      restoreIosInfoPlist('original', plistPath: plist.path);

      // renameSync would otherwise install the temp's default mode,
      // silently rewriting a 0600 file across the cycle.
      expect(plist.statSync().mode & 0xFFF, int.parse('600', radix: 8));
      expect(plist.readAsStringSync(), 'original');
    }, skip: Platform.isWindows ? 'POSIX mode bits' : false);

    test('a stale temp from a killed run is swept by the next write', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist8');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final plist = File('${dir.path}/Info.plist')
        ..writeAsStringSync('stamped');
      final stale = File('${dir.path}/.Info.plist.99999.tmp')
        ..writeAsStringSync('stale');

      restoreIosInfoPlist('original', plistPath: plist.path);

      expect(stale.existsSync(), isFalse);
      final leftovers = dir
          .listSync()
          .map((e) => e.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('the stamp write is atomic too — no leftover temp', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist5');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final plist = File('${dir.path}/Info.plist')
        ..writeAsStringSync('<dict>\n</dict>\n');

      final saved = writeBaselineIdToIosInfoPlist('u-1', plistPath: plist.path);

      expect(saved, '<dict>\n</dict>\n');
      expect(plist.readAsStringSync(), contains('FCPBaselineId'));
      final leftovers = dir
          .listSync()
          .map((e) => e.path)
          .where((path) => path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

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
