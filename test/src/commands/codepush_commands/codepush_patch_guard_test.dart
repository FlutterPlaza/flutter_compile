import 'dart:async';
import 'dart:io';

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

  group('early argument validation', () {
    late ParsedArgsPatchCommand cmd;

    setUp(() {
      cmd = ParsedArgsPatchCommand(MockLogger());
    });

    test(
        '--build with a --patch-file naming the future build output '
        'is NOT rejected up front — in any legitimate spelling', () {
      // On a clean tree the output does not exist until the build
      // runs; the post-build in-place check owns that flow. Rejecting
      // here broke `--build --patch-file build/codepush/patch.fcppatch`
      // on every fresh clone and CI runner.
      // Every row has provenance INDEPENDENT of Directory.current —
      // a row derived from the cwd would pass for any comparator.
      // The last row is the symlinked/bind-mounted-prefix shape
      // (macOS /var → /private/var, a CI workspace mount) that
      // full-path comparison got wrong and that motivated judging
      // by basename alone.
      for (final spelling in [
        CodePushPatchSubCommand.kPatchOutputPath,
        './${CodePushPatchSubCommand.kPatchOutputPath}',
        'build/./codepush/patch.fcppatch',
        'build/codepush/../codepush/patch.fcppatch',
        '/var/ci/workspace/proj/build/codepush/patch.fcppatch',
      ]) {
        cmd.parsedArgs = cmd.argParser.parse(
          ['--build', '--patch-file', spelling],
        );
        expect(cmd.earlyPatchFileError(), isNull, reason: spelling);
      }
    });

    test(
        '--build with a TYPO in --patch-file fails fast — the build '
        'can never create that path', () {
      cmd.parsedArgs = cmd.argParser.parse(
        // One 'p' — the classic misspelling of the output path.
        ['--build', '--patch-file', 'build/codepush/patch.fcpatch'],
      );
      expect(
        cmd.earlyPatchFileError(),
        allOf(
          contains('build/codepush/patch.fcpatch'),
          // The --build message names the path the build writes —
          // the fix the operator almost certainly wants.
          contains(CodePushPatchSubCommand.kPatchOutputPath),
        ),
      );
    });

    test('without --build a missing explicit patch file fails fast', () {
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-file', '/definitely/not/there.fcppatch'],
      );
      expect(
        cmd.earlyPatchFileError(),
        allOf(
          contains('/definitely/not/there.fcppatch'),
          // The --build guidance must be ABSENT here: without --build
          // the user genuinely named a missing file, and pointing at
          // the build output would mislead. Pins the branch flag.
          isNot(contains(CodePushPatchSubCommand.kPatchOutputPath)),
        ),
      );
    });

    test('signing preconditions are checked before any build work', () async {
      // --unsigned decides without touching config or disk.
      cmd.parsedArgs = cmd.argParser.parse(['--unsigned']);
      expect(await cmd.signingPreconditionError(), isNull);

      // An explicit key naming a missing file is a pure argument
      // mistake — the worst place to learn it is after the build.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--signing-key', '/definitely/not/a.pem'],
      );
      expect(
        await cmd.signingPreconditionError(),
        contains('/definitely/not/a.pem'),
      );

      // Empty is REJECTED, not treated as absent: an unset CI
      // variable must fail fast, not silently sign with a stored
      // key the user did not name.
      cmd.parsedArgs = cmd.argParser.parse(['--signing-key', '']);
      expect(
        await cmd.signingPreconditionError(),
        contains('Empty --signing-key'),
      );

      // An explicit key that exists passes without a config lookup.
      final key = File(
        '${Directory.systemTemp.createTempSync('fcp_sign').path}/k.pem',
      )..writeAsBytesSync([1]);
      addTearDown(() => key.parent.deleteSync(recursive: true));
      cmd.parsedArgs = cmd.argParser.parse(['--signing-key', key.path]);
      expect(await cmd.signingPreconditionError(), isNull);
      // The no-flag row depends on ~/.flutter_compilerc and is
      // deliberately not pinned here (no config seam).
    });

    test('an existing explicit patch file passes; absent flag passes', () {
      final tmp = File(
        '${Directory.systemTemp.createTempSync('fcp_guard').path}/p.fcppatch',
      )..writeAsBytesSync([1]);
      addTearDown(() => tmp.parent.deleteSync(recursive: true));

      cmd.parsedArgs = cmd.argParser.parse(['--patch-file', tmp.path]);
      expect(cmd.earlyPatchFileError(), isNull);

      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.earlyPatchFileError(), isNull);
    });

    test('parseRollout: strict — a typo re-runs, never widens', () {
      int? parsed(List<String> args) {
        cmd.parsedArgs = cmd.argParser.parse(args);
        return cmd.parseRollout();
      }

      expect(parsed(['--rollout', '50']), 50);
      expect(parsed([]), 100);
      // Padded is trimmed at the boundary like --release-id: ' 50'
      // was correct before the strict parse and stays correct.
      expect(parsed(['--rollout', ' 50 ']), 50);
      // Every invalid shape is a rejection, NOT a silent 100.
      expect(parsed(['--rollout', '50%']), isNull);
      expect(parsed(['--rollout', '0.5']), isNull);
      expect(parsed(['--rollout', 'fifty']), isNull);
      expect(parsed(['--rollout', '0']), isNull);
      expect(parsed(['--rollout', '101']), isNull);
      // Shapes bare int.tryParse would admit — digits only.
      expect(parsed(['--rollout', '0x64']), isNull);
      expect(parsed(['--rollout', '+50']), isNull);
      // Passes the regex, overflows the parse: must be a clean null,
      // not a FormatException with a stack trace.
      expect(parsed(['--rollout', '9' * 20]), isNull);
    });

    test('platformArgOrError: normalize, validate, never silently drop', () {
      (String?, String?) resolved(List<String> args) {
        cmd.parsedArgs = cmd.argParser.parse(args);
        return cmd.platformArgOrError();
      }

      expect(resolved([]), (null, null));
      // Wrong case previously matched NO branch and silently dropped
      // the device-side baseline check — normalize instead.
      expect(resolved(['--platform', 'iOS']), ('ios', null));
      expect(resolved(['--platform', ' apk ']), ('apk', null));
      // 'android' is the fallback alias the help never listed — it
      // has always worked and must keep working.
      expect(resolved(['--platform', 'android']), ('android', null));
      // Free text is a fast exit 64, never an ungated upload.
      final (value, error) = resolved(['--platform', 'web']);
      expect(value, isNull);
      expect(error, contains('web'));
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
