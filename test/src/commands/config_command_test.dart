import 'package:flutter_compile/src/command_runner.dart';
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
}
