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

    test(
        'the flag wins IN ITS OWN CASING — why the release guard '
        'must compare exactly', () {
      // Devices present the EMBEDDED id verbatim and the server's
      // compare is exact, so whatever this resolver returns is the
      // identity the release lives or dies by. The flag beating a
      // case-different embedded id here is precisely why run()'s
      // flag-vs-embedded guard refuses anything but an exact match:
      // a case-tolerant acceptance would record 'abc' for devices
      // that present 'ABC'.
      expect(
        resolveIosBaselineId(explicitFlag: 'abc', fromBuiltApp: 'ABC'),
        'abc',
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

  group('readBaselineIdFromSourceInfoPlist', () {
    test('reads an FCPBaselineId from an XML source plist', () {
      final root = Directory.systemTemp.createTempSync('fcp_src');
      addTearDown(() => root.deleteSync(recursive: true));
      final plist = File('${root.path}/Info.plist')
        ..writeAsStringSync(
          '<dict>\n\t<key>FCPBaselineId</key>\n'
          '\t<string>src-id-1</string>\n</dict>\n',
        );
      expect(
        readBaselineIdFromSourceInfoPlist(plistPath: plist.path),
        'src-id-1',
      );
    });

    test('absent file and a plist without the key both read null', () {
      final root = Directory.systemTemp.createTempSync('fcp_src2');
      addTearDown(() => root.deleteSync(recursive: true));
      expect(
        readBaselineIdFromSourceInfoPlist(
          plistPath: '${root.path}/none.plist',
        ),
        isNull,
      );
      final bare = File('${root.path}/Info.plist')
        ..writeAsStringSync('<dict>\n</dict>\n');
      expect(
        readBaselineIdFromSourceInfoPlist(plistPath: bare.path),
        isNull,
      );
    });

    test(
      'reads the id from a BINARY source plist via the plutil fallback '
      '— the branch that keeps the stamp-failure warning honest',
      () {
        final root = Directory.systemTemp.createTempSync('fcp_src3');
        addTearDown(() => root.deleteSync(recursive: true));
        final plist = File('${root.path}/Info.plist')
          ..writeAsStringSync(
            '<dict>\n\t<key>FCPBaselineId</key>\n'
            '\t<string>bin-src-id</string>\n</dict>\n',
          );
        final convert = Process.runSync(
          'plutil',
          ['-convert', 'binary1', plist.path],
        );
        expect(convert.exitCode, 0, reason: 'plutil must convert');
        // XML regex misses the binary file; only the plutil fallback
        // can find the id — the read-only-ios/Runner/ + pre-committed
        // -binary-plist case round 13 was raised about.
        expect(
          readBaselineIdFromSourceInfoPlist(plistPath: plist.path),
          'bin-src-id',
        );
      },
      skip: !Platform.isMacOS ? 'plutil is macOS-only' : null,
    );
  });

  group('writeBaselineIdToIosInfoPlist edge shapes', () {
    test('a plist with no closing dict returns null, file untouched', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist9');
      addTearDown(() => root.deleteSync(recursive: true));
      final plist = File('${root.path}/Info.plist')
        ..writeAsStringSync('not a plist at all');

      expect(
        writeBaselineIdToIosInfoPlist('u-1', plistPath: plist.path),
        isNull,
      );
      expect(plist.readAsStringSync(), 'not a plist at all');
    });

    test(
        'a non-UTF-8 plist throws FileSystemException naming the '
        'decode — the empirical premise of the stamp guard split', () {
      // Load-bearing and EMPIRICAL: dart:io's readAsStringSync
      // reports a stray non-UTF-8 byte (binary plist family) as a
      // FileSystemException whose message names the decode, NOT as
      // a FormatException. run()'s stamp guard splits the cause on
      // that message; if a future SDK changes the type or wording,
      // this row goes red before the guard silently misdiagnoses a
      // binary plist as a permissions problem.
      final root = Directory.systemTemp.createTempSync('fcp_plist10');
      addTearDown(() => root.deleteSync(recursive: true));
      final plist = File('${root.path}/Info.plist')
        ..writeAsBytesSync([0x62, 0x70, 0x6C, 0xFF, 0xFE, 0x00]);

      expect(
        () => writeBaselineIdToIosInfoPlist('u-1', plistPath: plist.path),
        throwsA(
          isA<FileSystemException>()
              .having(
                (e) => e.message,
                'message',
                contains('Failed to decode'),
              )
              // No OSError is the STRUCTURAL half of the guard's
              // discriminator: OS-level failures (rename included,
              // whose message embeds the destination path) always
              // carry one; the decode exception never does.
              .having((e) => e.osError, 'osError', isNull),
        ),
      );
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

    test('a DANGLING temp symlink is swept too', () {
      final root = Directory.systemTemp.createTempSync('fcp_plist10');
      addTearDown(() => root.deleteSync(recursive: true));
      final dir = Directory('${root.path}/ios/Runner')
        ..createSync(recursive: true);
      final plist = File('${dir.path}/Info.plist')
        ..writeAsStringSync('stamped');
      final staleLink = '${dir.path}/.Info.plist.88888.tmp';
      Link(staleLink).createSync('${root.path}/gone.tmp');

      restoreIosInfoPlist('original', plistPath: plist.path);

      // File.existsSync is blind to a dangling link; the sweep must
      // not be — the same reasoning as the saved-baseline temp
      // occupant cleanup.
      expect(
        FileSystemEntity.typeSync(staleLink, followLinks: false),
        FileSystemEntityType.notFound,
      );
    }, skip: Platform.isWindows ? 'file symlinks need privileges' : false);

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

    // The null-cause seam (round-17 Low): one caller escalates a null
    // to exit 64, so WHICH branch produced it must be reportable —
    // and a successful read must stay silent.
    test('onNullCause names the missing-bundle branch', () {
      final causes = <String>[];
      expect(
        readBaselineIdFromBuiltAppPlist(
          appPath: '${tmp.path}/nope.app',
          onNullCause: causes.add,
        ),
        isNull,
      );
      expect(causes, hasLength(1));
      expect(causes.single, contains('missing from the built bundle'));
    });

    test('onNullCause names the key-absent branch, exactly once', () {
      final causes = <String>[];
      final appPath = writePlist(
        xmlPlist.replaceAll('FCPBaselineId', 'SomethingElse'),
      );
      expect(
        readBaselineIdFromBuiltAppPlist(
          appPath: appPath,
          onNullCause: causes.add,
        ),
        isNull,
      );
      expect(causes, hasLength(1));
      expect(causes.single, contains('absent (or blank)'));
    });

    test(
        'onNullCause names the unreadable-as-XML branch (the '
        'motivating binary-plist-without-plutil shape)', () {
      final causes = <String>[];
      // Non-UTF-8 garbage: plutil (where present) exits non-zero on
      // it, and the XML fallback's readAsStringSync throws — the one
      // branch whose cause previously had no row. Holds on macOS
      // (plutil fails) and Linux CI (plutil absent) alike.
      final app = Directory('${tmp.path}/Runner.app')..createSync();
      File('${app.path}/Info.plist')
          .writeAsBytesSync([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0xC0]);
      expect(
        readBaselineIdFromBuiltAppPlist(
          appPath: app.path,
          onNullCause: causes.add,
        ),
        isNull,
      );
      expect(causes, hasLength(1));
      expect(causes.single, contains('could not be read as XML'));
    });

    test('onNullCause is never called on a successful read', () {
      final causes = <String>[];
      final appPath = writePlist(xmlPlist);
      expect(
        readBaselineIdFromBuiltAppPlist(
          appPath: appPath,
          onNullCause: causes.add,
        ),
        'd7eebb10-1234-4abc-9def-0123456789ab',
      );
      expect(causes, isEmpty);
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
