import 'package:flutter_compile/src/commands/codepush_commands/_codepush_setup.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_versions.dart';
import 'package:test/test.dart';

/// Command-level gating and display helpers for platform-aware support.
void main() {
  group('CodePushSetupSubCommand.setupNeedsIosSupport', () {
    test('explicit iOS targets require iOS support', () {
      for (final p in ['ios', 'ipa', 'ios-arm64']) {
        expect(
          CodePushSetupSubCommand.setupNeedsIosSupport(
            targetPlatform: p,
            isMacOsHost: false,
          ),
          isTrue,
          reason: p,
        );
      }
    });

    test('target-less runs require iOS support only on macOS hosts', () {
      expect(
        CodePushSetupSubCommand.setupNeedsIosSupport(
          targetPlatform: null,
          isMacOsHost: true,
        ),
        isTrue,
      );
      expect(
        CodePushSetupSubCommand.setupNeedsIosSupport(
          targetPlatform: null,
          isMacOsHost: false,
        ),
        isFalse,
        reason: 'Linux/Windows overlay step is a no-op — a version live '
            'for any platform may proceed',
      );
    });

    test('explicit host targets never require iOS support', () {
      for (final p in ['linux-x64', 'darwin-arm64', 'windows-x64', 'macos']) {
        expect(
          CodePushSetupSubCommand.setupNeedsIosSupport(
            targetPlatform: p,
            isMacOsHost: true,
          ),
          isFalse,
          reason: p,
        );
      }
    });
  });

  group('CodePushVersionsSubCommand.friendlyPlatforms', () {
    test('maps artifact ids to user-facing names, sorted and deduped', () {
      expect(
        CodePushVersionsSubCommand.friendlyPlatforms(
          {'ios-arm64': 'r1', 'android-arm64': 'r2'},
        ),
        ['android', 'ios'],
      );
    });

    test('unknown ids pass through so future targets appear', () {
      expect(
        CodePushVersionsSubCommand.friendlyPlatforms({'web-wasm': 'r'}),
        ['web-wasm'],
      );
    });

    test('null and empty degrade to an empty list', () {
      expect(CodePushVersionsSubCommand.friendlyPlatforms(null), isEmpty);
      expect(CodePushVersionsSubCommand.friendlyPlatforms({}), isEmpty);
    });
  });
}
