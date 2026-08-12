import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  group('findIosBaselineAppBinaryPath', () {
    late CodePushBuildService service;
    late Directory tmp;

    const appBinary =
        'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App';
    const archiveBinary =
        'build/ios/archive/Runner.xcarchive/Products/Applications/'
        'Runner.app/Frameworks/App.framework/App';

    // All paths are anchored on the temp dir explicitly: mutating the
    // process-global Directory.current is a chdir(2) that races the
    // other concurrently-running test isolates.
    String p(String rel) => '${tmp.path}/$rel';
    String? find() =>
        service.findIosBaselineAppBinaryPath(projectRoot: tmp.path);

    setUp(() {
      service = CodePushBuildService(logger: MockLogger());
      tmp = Directory.systemTemp.createTempSync('fcp_ios_baseline_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns null when no release build output exists', () {
      expect(find(), isNull);
    });

    test('returns the App binary inside the built Runner.app', () {
      File(p(appBinary))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      expect(find(), p(appBinary));
    });

    test('recognizes the xcarchive output of "flutter build ipa"', () {
      File(p(archiveBinary))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      expect(find(), p(archiveBinary));
    });

    test('the newest build output wins when both layouts exist', () {
      File(p(appBinary))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      File(p(archiveBinary))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [4, 5, 6]);
      // Make the archive strictly newer.
      File(p(archiveBinary)).setLastModifiedSync(
        File(p(appBinary)).statSync().modified.add(const Duration(minutes: 5)),
      );
      expect(find(), p(archiveBinary));
    });

    test('a kernel without a built app is not a substitute', () {
      // The old behavior fell back to the newest app.dill — tens of MB
      // on real apps and over the upload cap. The helper must never
      // report a kernel path.
      File(p('.dart_tool/flutter_build/abc123/app.dill'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      expect(find(), isNull);
    });
  });
}
