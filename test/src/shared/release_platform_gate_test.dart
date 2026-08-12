import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:test/test.dart';

void main() {
  group('releaseNeedsExplicitPlatform', () {
    test('a flagless release in a dual-platform project needs --platform', () {
      expect(
        CodePushBuildService.releaseNeedsExplicitPlatform(
          explicitPlatform: null,
          builtPlatform: null,
          hasAndroidDir: true,
          hasIosDir: true,
        ),
        isTrue,
      );
    });

    test('an explicit --platform always passes', () {
      expect(
        CodePushBuildService.releaseNeedsExplicitPlatform(
          explicitPlatform: 'apk',
          builtPlatform: null,
          hasAndroidDir: true,
          hasIosDir: true,
        ),
        isFalse,
      );
    });

    test('a platform recorded by --build always passes', () {
      expect(
        CodePushBuildService.releaseNeedsExplicitPlatform(
          explicitPlatform: null,
          builtPlatform: 'ios',
          hasAndroidDir: true,
          hasIosDir: true,
        ),
        isFalse,
      );
    });

    test('single-platform projects keep the flagless flow', () {
      expect(
        CodePushBuildService.releaseNeedsExplicitPlatform(
          explicitPlatform: null,
          builtPlatform: null,
          hasAndroidDir: true,
          hasIosDir: false,
        ),
        isFalse,
      );
      expect(
        CodePushBuildService.releaseNeedsExplicitPlatform(
          explicitPlatform: null,
          builtPlatform: null,
          hasAndroidDir: false,
          hasIosDir: true,
        ),
        isFalse,
      );
    });
  });
}
