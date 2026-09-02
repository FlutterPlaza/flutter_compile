@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter_compile/src/commands/codepush_commands/_codepush_init.dart';
import 'package:flutter_compile/src/commands/config_command.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';

void main() {
  final tempHome = TempHome();
  late Directory projectA;
  late Directory projectB;

  Future<void> writeMachineAppId(String id) => F.writeKeyValueToRcConfig(
        File('${F.homeDir()}/${CodePushClient.rcFileName}'),
        Constants.codePushAppIdKey,
        id,
      );

  Directory makeProject(String name) {
    final dir = Directory('${tempHome.path}/$name')..createSync();
    File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $name\n');
    return dir;
  }

  setUp(() {
    tempHome.setUp();
    projectA = makeProject('app_a');
    projectB = makeProject('app_b');
  });

  tearDown(tempHome.tearDown);

  group('projectRcFile', () {
    test('anchors on the nearest pubspec.yaml, from a subdirectory', () {
      final nested = Directory('${projectA.path}/lib/src')
        ..createSync(recursive: true);

      expect(
        CodePushClient.projectRcFile(from: nested)?.path,
        '${projectA.path}/${CodePushClient.rcFileName}',
      );
    });

    test('is null outside a project — nothing to hang the value on', () {
      final loose = Directory('${tempHome.path}/not_a_project')..createSync();

      expect(CodePushClient.projectRcFile(from: loose), isNull);
    });
  });

  group('getAppId resolution order', () {
    test('a project-local id wins over the machine-wide one', () async {
      await writeMachineAppId('machine-app');
      await F.writeKeyValueToRcConfig(
        File('${projectA.path}/${CodePushClient.rcFileName}'),
        Constants.codePushAppIdKey,
        'project-a-app',
      );

      expect(
        await CodePushClient.getAppId(projectDir: projectA),
        'project-a-app',
      );
    });

    test(
        'falls back to the machine-wide id when the project has none — a '
        'setup made before the split keeps resolving what it always did',
        () async {
      await writeMachineAppId('machine-app');

      expect(
        await CodePushClient.getAppId(projectDir: projectA),
        'machine-app',
      );
    });

    test('a blank project value falls through rather than resolving to nothing',
        () async {
      await writeMachineAppId('machine-app');
      await F.writeKeyValueToRcConfig(
        File('${projectA.path}/${CodePushClient.rcFileName}'),
        Constants.codePushAppIdKey,
        '   ',
      );

      expect(
        await CodePushClient.getAppId(projectDir: projectA),
        'machine-app',
      );
    });

    test('null when neither file names one', () async {
      expect(await CodePushClient.getAppId(projectDir: projectA), isNull);
    });

    // The project file is committed, team-shared and documented as
    // hand-editable. `codepush_app_id: <id>` is the natural spelling and
    // leaves a leading space; untrimmed it url-encodes as `%20<id>`, the
    // server answers "app not found", and every echo of the value looks
    // correct.
    test('trims a hand-edited project value written as "key: value"', () async {
      File('${projectA.path}/${CodePushClient.rcFileName}').writeAsStringSync(
        '${Constants.codePushAppIdKey}: project-a-app\n',
      );

      expect(
        await CodePushClient.getAppId(projectDir: projectA),
        'project-a-app',
      );
    });

    test('trims the machine-wide value too', () async {
      File('${F.homeDir()}/${CodePushClient.rcFileName}').writeAsStringSync(
        '${Constants.codePushAppIdKey}: machine-app \n',
      );

      expect(await CodePushClient.getMachineAppId(), 'machine-app');
      expect(
        await CodePushClient.getAppId(projectDir: projectA),
        'machine-app',
      );
    });
  });

  group('storeAppId scoping', () {
    test("a second project's init no longer repoints the first (issue #73)",
        () async {
      // Project A pinned itself by running init once (writing its own
      // project file) — the documented migration step for setups that
      // predate project-scoped ids.
      await CodePushClient.storeAppId('app-a-id', projectDir: projectA);
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-a-id');

      // Project B is set up later on the same laptop.
      final written = await CodePushClient.storeAppId(
        'app-b-id',
        projectDir: projectB,
      );

      expect(written, '${projectB.path}/${CodePushClient.rcFileName}');
      expect(await CodePushClient.getAppId(projectDir: projectB), 'app-b-id');
      // The whole point: A still resolves A through its project file.
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-a-id');
      // The machine-wide file mirrors the LATEST init as a fallback for
      // callers that resolve without a working directory (the IDE
      // extensions, cwd-less daemon RPCs) — for them this is exactly
      // the pre-project-file behavior, no regression. Every cwd-aware
      // path prefers the project file, as asserted above.
      expect(await CodePushClient.getMachineAppId(), 'app-b-id');
    });

    test(
        'a legacy machine-only project stays exposed to the repoint until '
        'it re-runs init (the documented migration boundary)', () async {
      // Project A never re-ran init: only the machine-wide id exists.
      await writeMachineAppId('app-a-id');
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-a-id');

      await CodePushClient.storeAppId('app-b-id', projectDir: projectB);

      // Without a project file, A falls through to the mirrored
      // machine value — exactly the pre-project-file behavior #73
      // describes. One init in A pins it permanently (previous test).
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-b-id');
    });

    test('falls back to the machine-wide file outside a project', () async {
      final loose = Directory('${tempHome.path}/not_a_project')..createSync();

      final written =
          await CodePushClient.storeAppId('loose-id', projectDir: loose);

      expect(written, '${F.homeDir()}/${CodePushClient.rcFileName}');
      expect(await CodePushClient.getMachineAppId(), 'loose-id');
    });

    test('leaves the project file\'s other keys alone', () async {
      final rc = File('${projectA.path}/${CodePushClient.rcFileName}');
      await F.writeKeyValueToRcConfig(rc, 'some_other_key', 'kept');

      await CodePushClient.storeAppId('app-a-id', projectDir: projectA);

      expect(
        await F.readValueForKeyFromRcConfig(rc, 'some_other_key'),
        'kept',
      );
    });
  });

  group('machineAppIdAdvisory', () {
    String? advise({
      required String? machineAppId,
      required String newAppId,
      required String appIdPath,
    }) =>
        machineAppIdAdvisory(
          machineAppId: machineAppId,
          newAppId: newAppId,
          appIdPath: appIdPath,
        );

    test(
        'names the repoint the mirror just performed, and the projects it '
        'moves', () {
      final text = advise(
        machineAppId: 'app-a-id',
        newAppId: 'app-b-id',
        appIdPath: '${projectB.path}/${CodePushClient.rcFileName}',
      );

      expect(text, isNotNull);
      expect(text, contains('app-a-id'));
      expect(text, contains('app-b-id'));
      expect(text, contains('--app-id'));
      // The sentence this replaced claimed the opposite of what the
      // same call had just done. `storeAppId` mirrors into the
      // machine-wide file on EVERY init, so an advisory that says
      // nothing moved is a written reassurance handed to the exact
      // population the mirror leaves exposed.
      expect(text, isNot(contains('nothing was repointed')));
      expect(text, isNot(contains('still resolves app-a-id')));
      expect(text, contains('repointed'));
    });

    test('says this project is pinned when a project file was written', () {
      final text = advise(
        machineAppId: 'app-a-id',
        newAppId: 'app-b-id',
        appIdPath: '${projectB.path}/${CodePushClient.rcFileName}',
      );

      expect(text, contains('${projectB.path}/${CodePushClient.rcFileName}'));
      expect(text, contains('pinned'));
    });

    test('silent when no machine-wide id exists', () {
      expect(
        advise(
          machineAppId: null,
          newAppId: 'app-b-id',
          appIdPath: '${projectB.path}/${CodePushClient.rcFileName}',
        ),
        isNull,
      );
      expect(
        advise(
          machineAppId: '  ',
          newAppId: 'app-b-id',
          appIdPath: '${projectB.path}/${CodePushClient.rcFileName}',
        ),
        isNull,
      );
    });

    test('silent when the machine-wide id is the same app', () {
      expect(
        advise(
          machineAppId: 'app-b-id',
          newAppId: ' app-b-id ',
          appIdPath: '${projectB.path}/${CodePushClient.rcFileName}',
        ),
        isNull,
      );
    });

    test(
        'still fires outside a project — the machine-wide file was '
        'repointed there too, and nothing pins this run', () {
      final text = advise(
        machineAppId: 'app-a-id',
        newAppId: 'app-b-id',
        appIdPath: '${F.homeDir()}/${CodePushClient.rcFileName}',
      );

      expect(text, isNotNull);
      expect(text, contains('repointed'));
      // No project file exists in this case, so there is nothing to
      // claim is pinned.
      expect(text, isNot(contains('pinned')));
    });
  });

  // Round-2 Critical: the advisory has to agree with `storeAppId`, and
  // the only way to keep that true is to run them against each other.
  group('machineAppIdAdvisory against real storeAppId behaviour', () {
    test('a file-less project resolves the NEW id the advisory names',
        () async {
      await writeMachineAppId('app-a-id');
      final machineBefore = await CodePushClient.getMachineAppId();

      final appIdPath =
          await CodePushClient.storeAppId('app-b-id', projectDir: projectB);

      final text = machineAppIdAdvisory(
        machineAppId: machineBefore,
        newAppId: 'app-b-id',
        appIdPath: appIdPath,
      );

      // projectA has no file of its own: this is the population the
      // advisory speaks for, and it now resolves app-b-id.
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-b-id');
      expect(text, isNotNull);
      expect(text, contains('app-b-id'));
      expect(text, isNot(contains('still resolves app-a-id')));
    });
  });

  group('projectScopedKeyAdvisory', () {
    test('warns that the project file shadows a machine-wide config set',
        () async {
      await F.writeKeyValueToRcConfig(
        File('${projectA.path}/${CodePushClient.rcFileName}'),
        Constants.codePushAppIdKey,
        'project-a-app',
      );

      final text = await projectScopedKeyAdvisory(
        Constants.codePushAppIdKey,
        projectDir: projectA,
      );

      expect(text, isNotNull);
      expect(text, contains('project-a-app'));
      expect(text, contains(CodePushClient.rcFileName));
    });

    test(
        'the structured form carries the pieces a JSON or daemon consumer '
        'needs, not just the sentence', () async {
      await F.writeKeyValueToRcConfig(
        File('${projectA.path}/${CodePushClient.rcFileName}'),
        Constants.codePushAppIdKey,
        'project-a-app',
      );

      final advisory = await projectScopedKeyAdvisoryFor(
        Constants.codePushAppIdKey,
        projectDir: projectA,
      );

      expect(advisory, isNotNull);
      expect(advisory!.key, Constants.codePushAppIdKey);
      expect(advisory.projectValue, 'project-a-app');
      expect(
        advisory.projectFile,
        '${projectA.path}/${CodePushClient.rcFileName}',
      );
      expect(advisory.toJson(), {
        'key': Constants.codePushAppIdKey,
        'project_file': advisory.projectFile,
        'project_value': 'project-a-app',
        'message': advisory.message,
      });
    });

    test('echoes the TRIMMED value — what getAppId actually resolves',
        () async {
      File('${projectA.path}/${CodePushClient.rcFileName}').writeAsStringSync(
        '${Constants.codePushAppIdKey}: project-a-app\n',
      );

      final advisory = await projectScopedKeyAdvisoryFor(
        Constants.codePushAppIdKey,
        projectDir: projectA,
      );

      expect(advisory?.projectValue, 'project-a-app');
      expect(
        advisory?.projectValue,
        await CodePushClient.getAppId(projectDir: projectA),
      );
    });

    test('silent for other keys and for projects without an override',
        () async {
      expect(
        await projectScopedKeyAdvisory('flutter_path', projectDir: projectA),
        isNull,
      );
      expect(
        await projectScopedKeyAdvisory(
          Constants.codePushAppIdKey,
          projectDir: projectA,
        ),
        isNull,
      );
    });
  });

  // The payload `fcp config list --json` and the daemon's `config.list`
  // both return. Shared so the CLI and the IDE cannot disagree about
  // which app id this project resolves.
  group('configListPayload', () {
    test('carries the machine-wide settings plus the project advisory',
        () async {
      await writeMachineAppId('machine-wide-app');
      await F.writeKeyValueToRcConfig(
        File('${projectA.path}/${CodePushClient.rcFileName}'),
        Constants.codePushAppIdKey,
        'project-a-app',
      );

      final payload = await configListPayload(projectDir: projectA);

      expect(payload[Constants.codePushAppIdKey], 'machine-wide-app');
      final advisories = payload[kConfigAdvisoriesKey] as Map<String, dynamic>?;
      expect(advisories, isNotNull);
      expect(
        (advisories![Constants.codePushAppIdKey]
            as Map<String, dynamic>)['project_value'],
        'project-a-app',
      );
    });

    test('omits the advisories key entirely when nothing is shadowed',
        () async {
      await writeMachineAppId('machine-wide-app');

      final payload = await configListPayload(projectDir: projectA);

      expect(payload.containsKey(kConfigAdvisoriesKey), isFalse);
    });
  });
}
