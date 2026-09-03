import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/commands/config_command.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';
import '../../helpers/test_helpers.dart';

void main() {
  group('config', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('config command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('config'));
    });

    test('config command has alias cf', () {
      final configCmd = commandRunner.commands['config']!;
      expect(configCmd.aliases, contains('cf'));
    });

    test('config list accepts --json flag', () {
      final configCmd = commandRunner.commands['config']!;
      final listCmd = configCmd.subcommands['list']!;
      expect(listCmd.argParser.options, contains('json'));
    });

    test('config command has list, get, set subcommands', () {
      final configCmd = commandRunner.commands['config']!;
      final subcommands = configCmd.subcommands;
      expect(subcommands, contains('list'));
      expect(subcommands, contains('get'));
      expect(subcommands, contains('set'));
    });
  });

  group('config set/get with temp home', () {
    final tempHome = TempHome();
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      tempHome.setUp();
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;
    });

    tearDown(tempHome.tearDown);

    test('config set writes value and config get reads it back', () async {
      var result = await commandRunner.run(
        ['config', 'set', 'engine', '/tmp/engine'],
      );
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('Set engine_path:/tmp/engine')).called(1);

      result = await commandRunner.run(['config', 'get', 'engine']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('engine_path:/tmp/engine')).called(1);
    });

    test('config get returns not found for missing key', () async {
      final result = await commandRunner.run(['config', 'get', 'nonexistent']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('Key not found: nonexistent')).called(1);
    });

    test('config list with no rc file shows empty message', () async {
      final result = await commandRunner.run(['config', 'list']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('No .flutter_compilerc file found.')).called(1);
    });

    test('config list shows entries after set', () async {
      await commandRunner.run(['config', 'set', 'flutter', '/tmp/flutter']);
      await commandRunner.run(['config', 'list']);
      verify(() => logger.info('flutter_path:/tmp/flutter')).called(1);
    });

    test('config list --json outputs JSON', () async {
      await commandRunner.run(['config', 'set', 'flutter', '/tmp/flutter']);
      await commandRunner.run(['config', 'list', '--json']);
      verify(
        () => logger.info('{"flutter_path":"/tmp/flutter"}'),
      ).called(1);
    });

    test('config set with no args returns usage', () async {
      final result = await commandRunner.run(['config', 'set']);
      expect(result, equals(ExitCode.usage.code));
    });

    test('config get with no args returns usage', () async {
      final result = await commandRunner.run(['config', 'get']);
      expect(result, equals(ExitCode.usage.code));
    });
  });

  // `config` is a view onto the machine-wide file, but the code push
  // commands resolve `codepush_app_id` per project — so every surface
  // that REPORTS the machine-wide value has to say when the project
  // overrides it, or it reports a value the next patch will not use.
  group('config reports a project-scoped codepush_app_id override', () {
    final tempHome = TempHome();
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;
    late Directory previousCwd;

    setUp(() {
      tempHome.setUp();
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;

      final project = Directory('${tempHome.path}/app_a')..createSync();
      File('${project.path}/pubspec.yaml').writeAsStringSync('name: app_a\n');
      File('${project.path}/${CodePushClient.rcFileName}')
          .writeAsStringSync('${Constants.codePushAppIdKey}:project-a-app\n');

      previousCwd = Directory.current;
      Directory.current = project;
    });

    // cwd first: TempHome deletes the directory the test is standing in.
    tearDown(() {
      Directory.current = previousCwd;
      tempHome.tearDown();
    });

    test('config list warns, even with nothing machine-wide to list', () async {
      final result = await commandRunner.run(['config', 'list']);

      expect(result, equals(ExitCode.success.code));
      verify(
        () => logger.warn(any(that: contains('project-a-app'))),
      ).called(1);
    });

    test('config list warns beside the machine-wide value it just printed',
        () async {
      await commandRunner.run(
        ['config', 'set', Constants.codePushAppIdKey, 'machine-wide-app'],
      );

      await commandRunner.run(['config', 'list']);

      verify(
        () => logger.info('${Constants.codePushAppIdKey}:machine-wide-app'),
      ).called(1);
      verify(
        () => logger.warn(any(that: contains('project-a-app'))),
      ).called(greaterThanOrEqualTo(1));
    });

    test('config list --json carries the advisory as structured data',
        () async {
      final result = await commandRunner.run(['config', 'list', '--json']);
      expect(result, equals(ExitCode.success.code));

      final printed = verify(() => logger.info(captureAny())).captured;
      final payload =
          json.decode(printed.last as String) as Map<String, dynamic>;
      final advisories = payload[kConfigAdvisoriesKey] as Map<String, dynamic>?;

      expect(advisories, isNotNull, reason: 'JSON consumers get no warn line');
      final advisory =
          advisories![Constants.codePushAppIdKey] as Map<String, dynamic>;
      expect(advisory['project_value'], 'project-a-app');
      expect(advisory['project_file'], contains(CodePushClient.rcFileName));
      expect(advisory['message'], contains('project-a-app'));
    });

    test(
        'config get does not print "Key not found" next to the value the '
        'project actually resolves', () async {
      final result = await commandRunner.run(
        ['config', 'get', Constants.codePushAppIdKey],
      );

      expect(result, equals(ExitCode.success.code));
      verifyNever(
        () => logger.info('Key not found: ${Constants.codePushAppIdKey}'),
      );
      verify(
        () => logger.warn(any(that: contains('project-a-app'))),
      ).called(1);
    });
  });
}
