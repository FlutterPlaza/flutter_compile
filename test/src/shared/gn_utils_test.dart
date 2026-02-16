import 'package:flutter_compile/src/shared/gn_utils.dart';
import 'package:test/test.dart';

void main() {
  group('shouldRunGn', () {
    test('skipGn=true always returns false', () {
      expect(
        shouldRunGn(
          forceGn: true,
          skipGn: true,
          clean: true,
          buildNinjaExists: false,
        ),
        isFalse,
      );
    });

    test('forceGn=true returns true', () {
      expect(
        shouldRunGn(
          forceGn: true,
          skipGn: false,
          clean: false,
          buildNinjaExists: true,
        ),
        isTrue,
      );
    });

    test('clean=true returns true', () {
      expect(
        shouldRunGn(
          forceGn: false,
          skipGn: false,
          clean: true,
          buildNinjaExists: true,
        ),
        isTrue,
      );
    });

    test('auto-detect returns false when build.ninja exists', () {
      expect(
        shouldRunGn(
          forceGn: false,
          skipGn: false,
          clean: false,
          buildNinjaExists: true,
        ),
        isFalse,
      );
    });

    test('auto-detect returns true when build.ninja does not exist', () {
      expect(
        shouldRunGn(
          forceGn: false,
          skipGn: false,
          clean: false,
          buildNinjaExists: false,
        ),
        isTrue,
      );
    });
  });

  group('resolveGnFlags', () {
    test('android arm64 debug unoptimized', () {
      final flags = resolveGnFlags(
        platform: 'android',
        cpu: 'arm64',
        mode: 'debug',
        unoptimized: true,
      );
      expect(flags, contains('--android'));
      expect(flags, contains('--android-cpu'));
      expect(flags, contains('arm64'));
      expect(flags, contains('--unoptimized'));
      expect(flags, isNot(contains('--runtime-mode')));
    });

    test('android arm profile optimized', () {
      final flags = resolveGnFlags(
        platform: 'android',
        cpu: 'arm',
        mode: 'profile',
        unoptimized: false,
      );
      expect(flags, contains('--android'));
      expect(flags, contains('arm'));
      expect(flags, isNot(contains('--unoptimized')));
      expect(flags, contains('--runtime-mode'));
      expect(flags, contains('profile'));
    });

    test('ios debug unoptimized (non-simulator)', () {
      final flags = resolveGnFlags(
        platform: 'ios',
        mode: 'debug',
        unoptimized: true,
      );
      expect(flags, contains('--ios'));
      expect(flags, isNot(contains('--simulator')));
      expect(flags, contains('--unoptimized'));
    });

    test('ios simulator on Apple Silicon', () {
      final flags = resolveGnFlags(
        platform: 'ios',
        mode: 'debug',
        unoptimized: true,
        simulator: true,
        hostArch: 'arm64',
      );
      expect(flags, contains('--ios'));
      expect(flags, contains('--simulator'));
      expect(flags, contains('--mac-cpu'));
      expect(flags, contains('arm64'));
    });

    test('ios simulator on Intel', () {
      final flags = resolveGnFlags(
        platform: 'ios',
        mode: 'debug',
        unoptimized: true,
        simulator: true,
        hostArch: 'x86_64',
      );
      expect(flags, contains('--ios'));
      expect(flags, contains('--simulator'));
      expect(flags, isNot(contains('--mac-cpu')));
    });

    test('host on Apple Silicon', () {
      final flags = resolveGnFlags(
        platform: 'host',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'arm64',
      );
      expect(flags, contains('--mac-cpu'));
      expect(flags, contains('arm64'));
      expect(flags, contains('--unoptimized'));
    });

    test('host on Intel', () {
      final flags = resolveGnFlags(
        platform: 'host',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'x86_64',
      );
      expect(flags, isNot(contains('--mac-cpu')));
    });

    test('macos on Apple Silicon', () {
      final flags = resolveGnFlags(
        platform: 'macos',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'arm64',
      );
      expect(flags, contains('--mac-cpu'));
      expect(flags, contains('arm64'));
    });

    test('linux debug', () {
      final flags = resolveGnFlags(
        platform: 'linux',
        mode: 'debug',
        unoptimized: true,
      );
      expect(flags, isNot(contains('--android')));
      expect(flags, isNot(contains('--ios')));
      expect(flags, isNot(contains('--web')));
      expect(flags, contains('--unoptimized'));
    });

    test('web debug unoptimized', () {
      final flags = resolveGnFlags(
        platform: 'web',
        mode: 'debug',
        unoptimized: true,
      );
      expect(flags, contains('--web'));
      expect(flags, contains('--unoptimized'));
    });

    test('release mode', () {
      final flags = resolveGnFlags(
        platform: 'host',
        mode: 'release',
        unoptimized: false,
      );
      expect(flags, contains('--runtime-mode'));
      expect(flags, contains('release'));
      expect(flags, isNot(contains('--unoptimized')));
    });

    test('debug mode does not add runtime-mode flag', () {
      final flags = resolveGnFlags(
        platform: 'host',
        mode: 'debug',
        unoptimized: true,
      );
      expect(flags, isNot(contains('--runtime-mode')));
    });

    test('defaults cpu to arm64 for android when not specified', () {
      final flags = resolveGnFlags(
        platform: 'android',
        mode: 'debug',
        unoptimized: true,
      );
      expect(flags, contains('arm64'));
    });
  });

  group('resolveOutputDir', () {
    test('android debug unopt arm64', () {
      final dir = resolveOutputDir(
        platform: 'android',
        cpu: 'arm64',
        mode: 'debug',
        unoptimized: true,
      );
      expect(dir, 'android_debug_unopt_arm64');
    });

    test('android release arm', () {
      final dir = resolveOutputDir(
        platform: 'android',
        cpu: 'arm',
        mode: 'release',
        unoptimized: false,
      );
      expect(dir, 'android_release_arm');
    });

    test('host debug unopt on Apple Silicon', () {
      final dir = resolveOutputDir(
        platform: 'host',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'arm64',
      );
      expect(dir, 'host_debug_unopt_arm64');
    });

    test('host debug unopt on Intel', () {
      final dir = resolveOutputDir(
        platform: 'host',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'x86_64',
      );
      expect(dir, 'host_debug_unopt');
    });

    test('ios debug sim unopt arm64', () {
      final dir = resolveOutputDir(
        platform: 'ios',
        mode: 'debug',
        unoptimized: true,
        simulator: true,
        hostArch: 'arm64',
      );
      expect(dir, 'ios_debug_sim_unopt_arm64');
    });

    test('ios debug (device)', () {
      final dir = resolveOutputDir(
        platform: 'ios',
        mode: 'debug',
        unoptimized: true,
        simulator: false,
      );
      expect(dir, 'ios_debug_unopt');
    });

    test('web debug unopt', () {
      final dir = resolveOutputDir(
        platform: 'web',
        mode: 'debug',
        unoptimized: true,
      );
      expect(dir, 'wasm_debug_unopt');
    });

    test('macos debug unopt arm64', () {
      final dir = resolveOutputDir(
        platform: 'macos',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'arm64',
      );
      expect(dir, 'host_debug_unopt_arm64');
    });

    test('linux debug unopt on Intel', () {
      final dir = resolveOutputDir(
        platform: 'linux',
        mode: 'debug',
        unoptimized: true,
        hostArch: 'x86_64',
      );
      expect(dir, 'host_debug_unopt');
    });

    test('host profile optimized arm64', () {
      final dir = resolveOutputDir(
        platform: 'host',
        mode: 'profile',
        unoptimized: false,
        hostArch: 'arm64',
      );
      expect(dir, 'host_profile_arm64');
    });
  });
}
