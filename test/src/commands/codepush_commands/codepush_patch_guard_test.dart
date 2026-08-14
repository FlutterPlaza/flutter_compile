import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_patch.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

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
      command.warnIfUnguardedRelease({'extendable_widgets': 'false'});
      command.warnIfUnguardedRelease({'interface_freeze': 0});
      verify(() => logger.warn(any())).called(2);
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
}
