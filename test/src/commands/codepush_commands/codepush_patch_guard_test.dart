import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_patch.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_platform_arg.dart';
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
      // Every row is nonexistent BY CONSTRUCTION (anchored under a
      // fresh temp dir where nothing is ever created), so each one
      // must be carried by the basename clause — a relative row
      // would resolve against the process cwd and, on a checkout
      // where a local --build smoke has run, return early from the
      // existsSync check without exercising the clause at all.
      // (Anchoring beats changing Directory.current, which is
      // process-global and races concurrently-running suites.) The
      // last row is the symlinked/bind-mounted-prefix shape (macOS
      // /var → /private/var, a CI workspace mount) that full-path
      // comparison got wrong and that motivated judging by basename
      // alone.
      final anchor = Directory.systemTemp.createTempSync('fcp_spell').path;
      addTearDown(() => Directory(anchor).deleteSync(recursive: true));
      for (final spelling in [
        '$anchor/${CodePushPatchSubCommand.kPatchOutputPath}',
        '$anchor/./${CodePushPatchSubCommand.kPatchOutputPath}',
        '$anchor/build/./codepush/patch.fcppatch',
        '$anchor/build/codepush/../codepush/patch.fcppatch',
        '/var/ci/workspace/proj/build/codepush/patch.fcppatch',
      ]) {
        cmd.parsedArgs = cmd.argParser.parse(
          ['--build', '--patch-file', spelling],
        );
        expect(cmd.patchFileArgCheck().error, isNull, reason: spelling);
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
        cmd.patchFileArgCheck().error,
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
        cmd.patchFileArgCheck().error,
        allOf(
          contains('/definitely/not/there.fcppatch'),
          // The --build guidance must be ABSENT here: without --build
          // the user genuinely named a missing file, and pointing at
          // the build output would mislead. Pins the branch flag.
          isNot(contains(CodePushPatchSubCommand.kPatchOutputPath)),
        ),
      );
    });

    test(
        'patch-file: empty rejects; existing-elsewhere under --build '
        'warns that the build output is ignored', () {
      // Present-but-blank REJECTS like its five siblings — the
      // blank-means-absent reading fell through to auto-discovery
      // and shipped whatever stale patch the workspace held.
      cmd.parsedArgs = cmd.argParser.parse(['--patch-file', '']);
      final blank = cmd.patchFileArgCheck();
      expect(blank.error, contains('Empty --patch-file'));
      // The 64/70 split is structural, not prose-matched: blank is a
      // usage error like its five siblings.
      expect(blank.isUsageError, isTrue);

      // Third state: the argument names a file that already EXISTS
      // elsewhere — under --build the build runs and its output is
      // silently discarded in favor of this file. Warn, not exit
      // (re-signing a saved patch is legitimate), naming both paths.
      final saved = File(
        '${Directory.systemTemp.createTempSync('fcp_saved').path}/old.fcppatch',
      )..writeAsBytesSync([1]);
      addTearDown(() => saved.parent.deleteSync(recursive: true));
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--patch-file', saved.path],
      );
      final existing = cmd.patchFileArgCheck();
      expect(existing.error, isNull);
      expect(
        existing.warning,
        allOf(
          contains(saved.path),
          contains(CodePushPatchSubCommand.kPatchOutputPath),
        ),
      );
      // Without --build the same file is the normal flow: silent.
      cmd.parsedArgs = cmd.argParser.parse(['--patch-file', saved.path]);
      expect(
        cmd.patchFileArgCheck(),
        (warning: null, error: null, isUsageError: false),
      );
      // A MISSING file keeps the software (70) classification.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-file', '/definitely/not/there.fcppatch'],
      );
      expect(cmd.patchFileArgCheck().isUsageError, isFalse);
    });

    test('blankArgError: blank rejects, absent keeps the fallback', () {
      // Deleting an entry from the flag list is a silent, fully
      // green regression — one row per flag holds the list in place.
      cmd.parsedArgs = cmd.argParser.parse(['--flutter-version', ' ']);
      expect(cmd.blankArgError(), contains('Empty --flutter-version'));
      cmd.parsedArgs = cmd.argParser.parse(['--package-prefix', '']);
      expect(cmd.blankArgError(), contains('Empty --package-prefix'));
      cmd.parsedArgs = cmd.argParser.parse(['--patch-entry-file', ' ']);
      expect(cmd.blankArgError(), contains('Empty --patch-entry-file'));
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.blankArgError(), isNull);
      cmd.parsedArgs = cmd.argParser.parse(['--flutter-version', '3.41.2']);
      expect(cmd.blankArgError(), isNull);
    });

    test(
        'rolloutErrorMessage names the unset-variable cause for the '
        'empty shape', () {
      cmd.parsedArgs = cmd.argParser.parse(['--rollout', '']);
      expect(cmd.parseRollout(), isNull);
      expect(cmd.rolloutErrorMessage(), contains('Empty --rollout'));
      cmd.parsedArgs = cmd.argParser.parse(['--rollout', '50%']);
      expect(cmd.rolloutErrorMessage(), contains('must be an integer'));
    });

    test('patchEntryFileArgError: missing and outside-lib fail early', () {
      final root = Directory.systemTemp.createTempSync('fcp_entry');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/lib/patch.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('void codePushPatch() {}');
      File('${root.path}/tool/outside.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('void codePushPatch() {}');

      // Missing: a pure argument mistake that used to surface only
      // after the fetch and the guard warning.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-entry-file', 'lib/typo.dart'],
      );
      expect(
        cmd.patchEntryFileArgError(projectRootOverride: root.path),
        contains('Patch entry source not found'),
      );
      // Outside lib/: same class, same early exit.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-entry-file', 'tool/outside.dart'],
      );
      expect(
        cmd.patchEntryFileArgError(projectRootOverride: root.path),
        contains('under `lib/`'),
      );
      // Valid and absent both pass (auto-discovery stays late).
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-entry-file', 'lib/patch.dart'],
      );
      expect(
        cmd.patchEntryFileArgError(projectRootOverride: root.path),
        isNull,
      );
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.patchEntryFileArgError(), isNull);
      // ABSOLUTE path under the override: exercises the isAbsolute
      // ternary's other branch (the round-31 lesson, applied here).
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-entry-file', '${root.path}/lib/patch.dart'],
      );
      expect(
        cmd.patchEntryFileArgError(projectRootOverride: root.path),
        isNull,
      );
    });

    test('buildOnlyFlagsWarning: iOS build-only flags warn when ignored', () {
      cmd.parsedArgs = cmd.argParser.parse(
        ['--patch-entry-file', 'lib/x.dart'],
      );
      expect(cmd.buildOnlyFlagsWarning(), contains('--patch-entry-file'));
      cmd.parsedArgs = cmd.argParser.parse(
        ['--swap-mode', '--include-uri', 'package:a/b.dart'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(),
        allOf(contains('--swap-mode'), contains('--include-uri')),
      );
      cmd.parsedArgs = cmd.argParser.parse(['--dart-define', 'A=1']);
      expect(cmd.buildOnlyFlagsWarning(), contains('--dart-define'));
      cmd.parsedArgs = cmd.argParser.parse(
        ['--package-prefix', 'package:x/'],
      );
      expect(cmd.buildOnlyFlagsWarning(), contains('--package-prefix'));
      cmd.parsedArgs = cmd.argParser.parse(
        ['--flutter-version', '3.41.2'],
      );
      expect(cmd.buildOnlyFlagsWarning(), contains('--flutter-version'));
      // With --build they are read; nothing warns.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--patch-entry-file', 'lib/x.dart'],
      );
      expect(cmd.buildOnlyFlagsWarning(), isNull);
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.buildOnlyFlagsWarning(), isNull);
    });

    test('signing preconditions are checked before any build work', () async {
      // (A bare --unsigned row would read the machine's stored-key
      // config — deliberately unpinned, no config seam. The rows
      // below are hermetic.)
      // --unsigned with a valid explicit key proceeds (it signs).
      final unsignedKey = File(
        '${Directory.systemTemp.createTempSync('fcp_sign_u').path}/k.pem',
      )..writeAsBytesSync([1]);
      addTearDown(() => unsignedKey.parent.deleteSync(recursive: true));
      cmd.parsedArgs = cmd.argParser.parse(
        ['--unsigned', '--signing-key', unsignedKey.path],
      );
      expect((await cmd.signingPreconditionError()).error, isNull);

      // An explicit key naming a missing file is a pure argument
      // mistake — the worst place to learn it is after the build.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--signing-key', '/definitely/not/a.pem'],
      );
      expect(
        (await cmd.signingPreconditionError()).error,
        contains('/definitely/not/a.pem'),
      );

      // Empty is REJECTED, not treated as absent: an unset CI
      // variable must fail fast, not silently sign with a stored
      // key the user did not name.
      cmd.parsedArgs = cmd.argParser.parse(['--signing-key', '']);
      final blankKey = await cmd.signingPreconditionError();
      expect(blankKey.error, contains('Empty --signing-key'));
      // Structural 64/70 split, like patchFileArgCheck: blank is
      // usage, missing-key stays software.
      expect(blankKey.isUsageError, isTrue);

      // A broken explicit key fails fast EVEN under --unsigned: the
      // late block signs whenever a key path is present, so this
      // state would otherwise still die after the whole build.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--unsigned', '--signing-key', '/definitely/not/a.pem'],
      );
      expect(
        (await cmd.signingPreconditionError()).error,
        contains('/definitely/not/a.pem'),
      );

      // --unsigned with an EMPTY key proceeds (unsigned) — matching
      // the late block, which ignores an empty key under --unsigned.
      cmd.parsedArgs = cmd.argParser.parse(['--unsigned', '--signing-key', '']);
      expect((await cmd.signingPreconditionError()).error, isNull);

      // Whitespace-only classifies as blank like every sibling —
      // the same unset variable as '', in both directions.
      cmd.parsedArgs = cmd.argParser.parse(['--signing-key', '  ']);
      final wsKey = await cmd.signingPreconditionError();
      expect(wsKey.error, contains('Empty --signing-key'));
      expect(wsKey.isUsageError, isTrue);
      cmd.parsedArgs =
          cmd.argParser.parse(['--unsigned', '--signing-key', '  ']);
      expect((await cmd.signingPreconditionError()).error, isNull);

      // An explicit key that exists passes without a config lookup.
      final key = File(
        '${Directory.systemTemp.createTempSync('fcp_sign').path}/k.pem',
      )..writeAsBytesSync([1]);
      addTearDown(() => key.parent.deleteSync(recursive: true));
      cmd.parsedArgs = cmd.argParser.parse(['--signing-key', key.path]);
      expect((await cmd.signingPreconditionError()).error, isNull);
      // Stored-key rows, pinned via the injectable read (the real
      // default reads ~/.flutter_compilerc).
      cmd.parsedArgs = cmd.argParser.parse([]);
      final gone = await cmd.signingPreconditionError(
        readStoredKey: () async => '/definitely/gone/key.pem',
      );
      expect(gone.error, contains('Stored signing key not found'));
      expect(gone.isUsageError, isFalse);
      // '--unsigned cannot skip a configured stored key.'
      cmd.parsedArgs = cmd.argParser.parse(['--unsigned']);
      final goneUnsigned = await cmd.signingPreconditionError(
        readStoredKey: () async => '/definitely/gone/key.pem',
      );
      expect(goneUnsigned.error, contains('Stored signing key not found'));
      // A whitespace rc round-trip classifies as absent: unsigned
      // proceeds, signed hits the no-key guidance.
      expect(
        (await cmd.signingPreconditionError(readStoredKey: () async => ' '))
            .error,
        isNull,
      );
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(
        (await cmd.signingPreconditionError(readStoredKey: () async => ' '))
            .error,
        contains('No signing key found'),
      );
    });

    test(
        'an existing explicit patch file passes; absent flag checks '
        'auto-discovery up front', () {
      final tmp = File(
        '${Directory.systemTemp.createTempSync('fcp_guard').path}/p.fcppatch',
      )..writeAsBytesSync([1]);
      addTearDown(() => tmp.parent.deleteSync(recursive: true));

      cmd.parsedArgs = cmd.argParser.parse(['--patch-file', tmp.path]);
      expect(cmd.patchFileArgCheck().error, isNull);

      // No flag, no --build, nothing discoverable: fail BEFORE the
      // fetch — the unguarded-release warning must not fire on a run
      // that then exits having risked nothing. (Root override keeps
      // the rows independent of the checkout's own build/ tree.)
      final bare = Directory.systemTemp.createTempSync('fcp_bare');
      addTearDown(() => bare.deleteSync(recursive: true));
      cmd.parsedArgs = cmd.argParser.parse([]);
      final none = cmd.patchFileArgCheck(projectRootOverride: bare.path);
      expect(none.error, contains('No patch file found'));
      expect(none.isUsageError, isTrue);

      // With a discoverable candidate (the legacy path included),
      // the absent flag proceeds.
      final discoverable = Directory.systemTemp.createTempSync('fcp_disc');
      addTearDown(() => discoverable.deleteSync(recursive: true));
      File('${discoverable.path}/'
          '${CodePushPatchSubCommand.kLegacyPatchOutputPath}')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      expect(
        cmd.patchFileArgCheck(projectRootOverride: discoverable.path).error,
        isNull,
      );
      // --build with no flag also proceeds (the build creates it).
      cmd.parsedArgs = cmd.argParser.parse(['--build']);
      expect(
        cmd.patchFileArgCheck(projectRootOverride: bare.path).error,
        isNull,
      );
    });

    test(
        'an EXISTING file under --build is judged by exact path: the '
        'legacy candidate with the matching basename warns', () {
      // A stale build/patch.fcppatch (same basename as the output)
      // used to slip the warning and be silently uploaded over the
      // fresh build output.
      final root = Directory.systemTemp.createTempSync('fcp_stale');
      addTearDown(() => root.deleteSync(recursive: true));
      final stale = File(
        '${root.path}/${CodePushPatchSubCommand.kLegacyPatchOutputPath}',
      )
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--patch-file', stale.path],
      );
      final check = cmd.patchFileArgCheck();
      expect(check.error, isNull);
      expect(
        check.warning,
        allOf(
          contains(stale.path),
          contains(CodePushPatchSubCommand.kPatchOutputPath),
        ),
      );

      // The SILENT direction: an existing file that IS the build
      // output (any spelling — normalized comparison) must not draw
      // the warning; dropping the comparison entirely would fire a
      // false warning on the ordinary repeat---build flow. Anchored
      // under a temp root via projectRootOverride — no test writes
      // into the checkout.
      final sameRoot = Directory.systemTemp.createTempSync('fcp_same');
      addTearDown(() => sameRoot.deleteSync(recursive: true));
      File('${sameRoot.path}/${CodePushPatchSubCommand.kPatchOutputPath}')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      for (final spelling in [
        '${sameRoot.path}/${CodePushPatchSubCommand.kPatchOutputPath}',
        '${sameRoot.path}/./${CodePushPatchSubCommand.kPatchOutputPath}',
        '${sameRoot.path}/build/./codepush/patch.fcppatch',
        // RELATIVE arg: exercises anchored()'s false branch — both
        // sides must resolve under the override root, or a relative
        // --patch-file would stat the process cwd while the output
        // resolves under the override (two roots, green tests).
        CodePushPatchSubCommand.kPatchOutputPath,
      ]) {
        cmd.parsedArgs = cmd.argParser.parse(
          ['--build', '--patch-file', spelling],
        );
        expect(
          cmd.patchFileArgCheck(projectRootOverride: sameRoot.path).warning,
          isNull,
          reason: spelling,
        );
      }

      // The STAT side of anchored(): a relative arg whose basename
      // is NOT the output's, so the two possible stat answers land
      // in different branches — without anchoring, the miss falls to
      // the basename clause (no match) and becomes a hard 'not
      // found' error instead of the existing-file advisory.
      File('${sameRoot.path}/saved/keep.fcppatch')
        ..createSync(recursive: true)
        ..writeAsBytesSync([1]);
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--patch-file', 'saved/keep.fcppatch'],
      );
      final rel = cmd.patchFileArgCheck(projectRootOverride: sameRoot.path);
      expect(rel.error, isNull);
      expect(rel.warning, contains('saved/keep.fcppatch'));
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

    test('baselineArgCheck: warnings, and the empty-value reject', () {
      final baseline = File(
        '${Directory.systemTemp.createTempSync('fcp_base').path}/b.so',
      )..writeAsBytesSync([1]);
      addTearDown(() => baseline.parent.deleteSync(recursive: true));

      // Valid baseline WITHOUT --build: read by nothing — the quiet
      // misreading must warn, not silently ignore.
      cmd.parsedArgs = cmd.argParser.parse(['--baseline', baseline.path]);
      expect(cmd.baselineArgCheck().$1, contains('only used together'));

      // Missing baseline WITH --build: full-snapshot advisory.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--baseline', '/definitely/not/b.so'],
      );
      expect(cmd.baselineArgCheck().$1, contains('full snapshot'));

      // Valid + --build: silent.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--baseline', baseline.path],
      );
      expect(cmd.baselineArgCheck(), (null, null));

      // Present-but-blank REJECTS like the four flags beside it —
      // pre-fix it silently uploaded a full snapshot with both
      // advisories suppressed.
      cmd.parsedArgs = cmd.argParser.parse(['--baseline', '']);
      final (warning, error) = cmd.baselineArgCheck();
      expect(warning, isNull);
      expect(error, contains('Empty --baseline'));
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
      // has always worked on the no-build paths and must keep
      // working there...
      expect(resolved(['--platform', 'android']), ('android', null));
      // ...but under --build it is a guaranteed failure AFTER a full
      // engine preparation (flutter build has no 'android'
      // subcommand) — fast exit naming the buildable pair instead.
      final (androidValue, androidError) =
          resolved(['--build', '--platform', 'android']);
      expect(androidValue, isNull);
      expect(androidError, contains('not a buildable target'));
      // Free text is a fast exit 64, never an ungated upload.
      final (value, error) = resolved(['--platform', 'web']);
      expect(value, isNull);
      expect(error, contains('web'));
      // Present-but-blank is rejected like an empty --signing-key —
      // an unset CI variable must not read as "no platform named".
      final (blankValue, blankError) = resolved(['--platform', '']);
      expect(blankValue, isNull);
      expect(blankError, contains('Empty --platform'));
      final (wsValue, wsError) = resolved(['--platform', '  ']);
      expect(wsValue, isNull);
      expect(wsError, contains('Empty --platform'));
    });

    test(
        'resolvedChannelOrError: trimmed, empty REJECTS like its '
        'siblings', () {
      (String?, String?) channel(List<String> args) {
        cmd.parsedArgs = cmd.argParser.parse(args);
        return cmd.resolvedChannelOrError();
      }

      expect(channel([]), ('production', null));
      expect(channel(['--channel', 'beta']), ('beta', null));
      // ' production ' with spaces would be a channel no device
      // polls — the upload succeeds and nothing is ever offered.
      expect(channel(['--channel', ' production ']), ('production', null));
      // Empty is an unset CI variable: a re-run, never a silent
      // publish to the widest channel at the default rollout (and
      // pre-fix the server stored '' verbatim — an inert patch).
      final (value, error) = channel(['--channel', '']);
      expect(value, isNull);
      expect(error, contains('Empty --channel'));
    });
  });

  group('nonBlankEntries', () {
    test('drops whitespace-only entries, keeps values UNTRIMMED', () {
      // A trimmed value would bake a different compile-time constant
      // into the patch than the release baked — the two commands
      // must produce identical constants for identical input.
      expect(
        nonBlankEntries(['A=1', '  ', 'BANNER=beta ', '']),
        ['A=1', 'BANNER=beta '],
      );
      expect(nonBlankEntries(null), isEmpty);
      expect(nonBlankEntries([]), isEmpty);
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
