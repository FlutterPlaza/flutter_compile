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
  });

  group('storeAppId scoping', () {
    test("a second project's init no longer repoints the first (issue #73)",
        () async {
      // Project A is the pre-existing, machine-wide setup.
      await writeMachineAppId('app-a-id');
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-a-id');

      // Project B is set up later on the same laptop.
      final written = await CodePushClient.storeAppId(
        'app-b-id',
        projectDir: projectB,
      );

      expect(written, '${projectB.path}/${CodePushClient.rcFileName}');
      expect(await CodePushClient.getAppId(projectDir: projectB), 'app-b-id');
      // The whole point: A still resolves A.
      expect(await CodePushClient.getAppId(projectDir: projectA), 'app-a-id');
      expect(await CodePushClient.getMachineAppId(), 'app-a-id');
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

    test('fires when a different machine-wide id is left behind', () {
      final text = advise(
        machineAppId: 'app-a-id',
        newAppId: 'app-b-id',
        appIdPath: '${projectB.path}/${CodePushClient.rcFileName}',
      );

      expect(text, isNotNull);
      expect(text, contains('app-a-id'));
      expect(text, contains('--app-id'));
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
        'silent when this run wrote the machine-wide file itself — there '
        'is no second value left to surprise anyone', () {
      expect(
        advise(
          machineAppId: 'app-a-id',
          newAppId: 'app-b-id',
          appIdPath: '${F.homeDir()}/${CodePushClient.rcFileName}',
        ),
        isNull,
      );
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
}
