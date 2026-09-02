@TestOn('!windows')
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_keys.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../../helpers/temp_home.dart';

class _MockLogger extends Mock implements Logger {}

void main() {
  group('existingSigningKeyWarning', () {
    final text = existingSigningKeyWarning('/keys/codepush_private.pem');

    test('names the key it found', () {
      expect(text, contains('/keys/codepush_private.pem'));
    });

    test(
        'leads with the consequence that costs something: no updates '
        'reach the installed base until a store release ships the new '
        'key', () {
      expect(text, contains('stops updates for every app already installed'));
      expect(text, contains('store release'));
    });

    test(
        'does not repeat the inversion it replaced — shipped patches '
        'keep verifying against the key their install holds', () {
      expect(text, contains('Patches you have already shipped keep working'));
      expect(text.toLowerCase(), isNot(contains('invalidat')));
    });

    test('frames rotation as an incident response, not hygiene', () {
      expect(text, contains('compromised key'));
    });
  });

  group('keys generate', () {
    late Directory tmp;
    late _MockLogger logger;
    final tempHome = TempHome();

    setUp(() {
      tempHome.setUp();
      tmp = Directory.systemTemp.createTempSync('keys_cli_');
      logger = _MockLogger();
      when(() => logger.warn(any())).thenReturn(null);
      when(() => logger.info(any())).thenReturn(null);
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
      tempHome.tearDown();
    });

    test(
        'an existing key without --force emits exactly the advisory, so '
        'the wording cannot drift from the tested body', () async {
      final keyPath = '${tmp.path}/codepush_private.pem';
      File(keyPath).writeAsStringSync('not a real key');

      final runner = CommandRunner<int>('fcp', 'test')
        ..addCommand(CodePushKeysSubCommand(logger));
      final exitCode = await runner.run([
        'keys',
        'generate',
        '--output-dir',
        tmp.path,
      ]);

      expect(exitCode, ExitCode.success.code);
      verify(() => logger.warn(existingSigningKeyWarning(keyPath))).called(1);
    });
  });
}
