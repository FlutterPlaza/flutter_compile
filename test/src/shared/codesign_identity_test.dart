import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:test/test.dart';

void main() {
  group('parseCodesignIdentity', () {
    test('takes the first Authority line (the leaf certificate)', () {
      const output = '''
Executable=/x/Runner.app/Runner
Identifier=com.example.app
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=764 flags=0x0(none) hashes=13+7 location=embedded
Signature size=4795
Authority=Apple Development: Jane Dev (ABCD123456)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
TeamIdentifier=KF76DSB8GZ
''';
      expect(
        CodePushBuildService.parseCodesignIdentity(output),
        'Apple Development: Jane Dev (ABCD123456)',
      );
    });

    test('ad-hoc signatures map to the ad-hoc identity marker', () {
      const output = '''
Executable=/x/Runner.app/Runner
Identifier=com.example.app
CodeDirectory v=20400 size=764 flags=0x2(adhoc) hashes=13+7 location=embedded
Signature=adhoc
Info.plist entries=32
''';
      expect(CodePushBuildService.parseCodesignIdentity(output), '-');
    });

    test('an unresolvable certificate chain returns null, not a literal', () {
      // codesign prints 'Authority=(unavailable)' when the signature is
      // present but the chain cannot be retrieved; signing with that
      // literal fails with a misleading 'no identity found'.
      const output = '''
Executable=/x/Runner.app/Runner
Identifier=com.example.app
Signature size=4795
Authority=(unavailable)
TeamIdentifier=KF76DSB8GZ
''';
      expect(CodePushBuildService.parseCodesignIdentity(output), isNull);
    });

    test('unsigned output returns null', () {
      const output = '/x/Runner.app: code object is not signed at all';
      expect(CodePushBuildService.parseCodesignIdentity(output), isNull);
    });

    test('unrecognizable output returns null', () {
      expect(CodePushBuildService.parseCodesignIdentity(''), isNull);
      expect(
        CodePushBuildService.parseCodesignIdentity('random text\nlines'),
        isNull,
      );
    });
  });
}
