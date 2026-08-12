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

    test(
        'macOS hosts always require iOS support — the overlay installer '
        'runs unconditionally there, whatever the target spelling', () {
      for (final p in [null, 'darwin-arm64', 'macos', 'linux-x64']) {
        expect(
          CodePushSetupSubCommand.setupNeedsIosSupport(
            targetPlatform: p,
            isMacOsHost: true,
          ),
          isTrue,
          reason: '$p on macOS',
        );
      }
    });

    test('off macOS, only explicit iOS spellings gate on iOS', () {
      for (final p in [null, 'linux-x64', 'windows-x64', 'darwin-arm64']) {
        expect(
          CodePushSetupSubCommand.setupNeedsIosSupport(
            targetPlatform: p,
            isMacOsHost: false,
          ),
          isFalse,
          reason: '$p off macOS — overlay step is a no-op',
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
