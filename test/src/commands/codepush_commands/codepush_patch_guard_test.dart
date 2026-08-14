import 'dart:async';

import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_patch.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

class MockCodePushClient extends Mock implements CodePushClient {}

/// Exposes the command with parsed args so the REAL flag read inside
/// [CodePushPatchSubCommand.warnIfUnguardedRelease] executes against a
/// real [ArgResults] (direct calls otherwise see a null `argResults`,
/// and the `?? false` default would mask a flag that silently became
/// a no-op).
class ParsedArgsPatchCommand extends CodePushPatchSubCommand {
  ParsedArgsPatchCommand(super.logger);

  ArgResults? parsedArgs;

  @override
  ArgResults? get argResults => parsedArgs;
}

void main() {
  group('warnIfUnguardedRelease', () {
    late MockLogger logger;
    late CodePushPatchSubCommand command;

    setUp(() {
      logger = MockLogger();
      when(() => logger.warn(any())).thenReturn(null);
      command = CodePushPatchSubCommand(logger);
    });

    test('guarding off => loud warn naming the consequence and the flag', () {
      command.warnIfUnguardedRelease(
        {'extendable_widgets': false, 'interface_freeze': true},
      );
      verify(
        () => logger.warn(
          any(
            that: allOf(
              contains('without widget guarding'),
              contains('will crash'),
              contains('--allow-unguarded-release'),
            ),
          ),
        ),
      ).called(1);
    });

    test(
        'freeze off => ONE warn naming the root cause, not a flag the '
        'user never passed', () {
      // --no-interface-freeze records extendable_widgets false too;
      // the guarding warn must not fire alongside.
      command.warnIfUnguardedRelease(
        {'interface_freeze': false, 'extendable_widgets': false},
      );
      verify(
        () => logger.warn(
          any(
            that: allOf(
              contains('without the interface freeze'),
              contains('will crash'),
              contains('--allow-unguarded-release'),
            ),
          ),
        ),
      ).called(1);
      verifyNever(() => logger.warn(any()));
    });

    test('off-shapes from a type-mismatched server still warn', () {
      // The deployed server returns real booleans; a string or int
      // echo must degrade to a FIRED warning, not an inert feature.
      // '0' is the string echo of a tinyint column; 0.0 rides on num
      // equality with the 0 row.
      command.warnIfUnguardedRelease({'extendable_widgets': 'false'});
      command.warnIfUnguardedRelease({'interface_freeze': 0});
      command.warnIfUnguardedRelease({'extendable_widgets': '0'});
      command.warnIfUnguardedRelease({'interface_freeze': 0.0});
      verify(() => logger.warn(any())).called(4);
    });

    test(
        'unknown stays silent: true, null values, absent keys, '
        'null release', () {
      command.warnIfUnguardedRelease(
        {'extendable_widgets': true, 'interface_freeze': true},
      );
      command.warnIfUnguardedRelease(
        {'extendable_widgets': null, 'interface_freeze': null},
      );
      // Absent keys: every pre-metadata release and every old server —
      // including every Android release, which never attests.
      command.warnIfUnguardedRelease({'snapshot_hash': 'abc'});
      command.warnIfUnguardedRelease(null);
      // Truthy-but-not-off garbage is unknown, not off.
      command.warnIfUnguardedRelease({'extendable_widgets': 'FALSE'});
      verifyNever(() => logger.warn(any()));
    });

    test('--allow-unguarded-release, parsed for real, silences it', () {
      final cmd = ParsedArgsPatchCommand(logger);
      cmd.parsedArgs = cmd.argParser.parse(['--allow-unguarded-release']);
      cmd.warnIfUnguardedRelease(
        {'extendable_widgets': false, 'interface_freeze': false},
      );
      verifyNever(() => logger.warn(any()));

      // And the default parse still warns — the flag read is live.
      final unacknowledged = ParsedArgsPatchCommand(logger);
      unacknowledged.parsedArgs = unacknowledged.argParser.parse([]);
      unacknowledged.warnIfUnguardedRelease({'extendable_widgets': false});
      verify(() => logger.warn(any())).called(1);
    });

    test('the flag is registered and not negatable', () {
      final option = command.argParser.options['allow-unguarded-release'];
      expect(option, isNotNull);
      expect(option!.negatable, isFalse);
    });
  });

  group('readTargetRelease', () {
    late MockLogger logger;
    late CodePushPatchSubCommand command;
    late MockCodePushClient client;

    setUp(() {
      logger = MockLogger();
      when(() => logger.warn(any())).thenReturn(null);
      when(() => logger.detail(any())).thenReturn(null);
      command = CodePushPatchSubCommand(logger);
      client = MockCodePushClient();
    });

    test('the fetched map is the one inspected — and is returned', () async {
      // The wire this seam exists to pin: delete either link and the
      // guard feature goes inert while every unit test stays green.
      final release = <String, dynamic>{
        'extendable_widgets': false,
        'interface_freeze': true,
      };
      // Future typed explicitly: run()'s .timeout(onTimeout: () => null)
      // dispatches on the future's RUNTIME type, and an inferred
      // Future<Map<String, bool>> rejects the null-returning onTimeout.
      when(
        () => client.getRelease(token: 't', releaseId: 'r-1'),
      ).thenAnswer((_) => Future<Map<String, dynamic>?>.value(release));

      final result = await command.readTargetRelease(
        client: client,
        token: 't',
        releaseId: 'r-1',
      );
      expect(result, same(release));
      verify(
        () => logger.warn(any(that: contains('without widget guarding'))),
      ).called(1);
    });

    test('a hung fetch degrades to null and warns about the lost gate',
        () async {
      when(() => client.getRelease(token: 't', releaseId: 'r-2')).thenAnswer(
        (_) => Completer<Map<String, dynamic>?>().future,
      );

      final result = await command.readTargetRelease(
        client: client,
        token: 't',
        releaseId: 'r-2',
        timeout: const Duration(milliseconds: 50),
      );
      expect(result, isNull);
      verify(
        () => logger.warn(
          any(
            that: allOf(
              contains('Could not read release r-2'),
              contains('device-side baseline check'),
            ),
          ),
        ),
      ).called(1);
    });

    test('a null fetch warns once and stays silent on guarding', () async {
      when(
        () => client.getRelease(token: 't', releaseId: 'r-3'),
      ).thenAnswer((_) => Future<Map<String, dynamic>?>.value(null));

      final result = await command.readTargetRelease(
        client: client,
        token: 't',
        releaseId: 'r-3',
      );
      expect(result, isNull);
      // Exactly the fetch warn — warnIfUnguardedRelease's
      // null-stays-silent contract must hold through the seam.
      verify(() => logger.warn(any())).called(1);
    });
  });

  group('baselineHashFrom', () {
    late CodePushPatchSubCommand command;

    setUp(() {
      command = CodePushPatchSubCommand(MockLogger());
    });

    test(
        'definite-looking garbage degrades to null, not a crash or '
        'a bogus gate', () {
      // Same rule as the 'FALSE' pin above: shapes a server should
      // never send must fall into the local fallback.
      expect(command.baselineHashFrom(null), isNull);
      expect(command.baselineHashFrom({}), isNull);
      expect(command.baselineHashFrom({'snapshot_hash': 42}), isNull);
      expect(command.baselineHashFrom({'snapshot_hash': ''}), isNull);
      // Shorter than the 16-char floor: a truncated echo must not
      // become a baseline identity no device can match.
      expect(command.baselineHashFrom({'snapshot_hash': 'abc123'}), isNull);
    });

    test('a real digest passes through untouched', () {
      final digest = 'a' * 64;
      expect(
        command.baselineHashFrom({'snapshot_hash': digest}),
        digest,
      );
    });
  });
}
