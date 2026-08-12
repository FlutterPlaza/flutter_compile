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
    late Directory oldCwd;

    const appBinary =
        'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App';

    setUp(() {
      service = CodePushBuildService(logger: MockLogger());
      oldCwd = Directory.current;
      tmp = Directory.systemTemp.createTempSync('fcp_ios_baseline_test');
      Directory.current = tmp;
    });

    tearDown(() {
      Directory.current = oldCwd;
      tmp.deleteSync(recursive: true);
    });

    test('returns null when no release build output exists', () {
      expect(service.findIosBaselineAppBinaryPath(), isNull);
    });

    test('returns the App binary inside the built Runner.app', () {
      File(appBinary)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      expect(service.findIosBaselineAppBinaryPath(), appBinary);
    });

    test('recognizes the xcarchive output of "flutter build ipa"', () {
      const archiveBinary =
          'build/ios/archive/Runner.xcarchive/Products/Applications/'
          'Runner.app/Frameworks/App.framework/App';
      File(archiveBinary)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      expect(service.findIosBaselineAppBinaryPath(), archiveBinary);
    });

    test('the newest build output wins when both layouts exist', () {
      const archiveBinary =
          'build/ios/archive/Runner.xcarchive/Products/Applications/'
          'Runner.app/Frameworks/App.framework/App';
      File(appBinary)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      File(archiveBinary)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [4, 5, 6]);
      // Make the archive strictly newer.
      File(archiveBinary).setLastModifiedSync(
        File(appBinary).statSync().modified.add(const Duration(minutes: 5)),
      );
      expect(service.findIosBaselineAppBinaryPath(), archiveBinary);
    });

    test('a kernel without a built app is not a substitute', () {
      // The old behavior fell back to the newest app.dill — tens of MB
      // on real apps and over the upload cap. The helper must never
      // report a kernel path.
      File('.dart_tool/flutter_build/abc123/app.dill')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(const [1, 2, 3]);
      expect(service.findIosBaselineAppBinaryPath(), isNull);
    });
  });
}
