import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('sdk', () {
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;
    });

    test('sdk command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('sdk'));
    });

    test('sdk command has install subcommand', () {
      final sdkCmd = commandRunner.commands['sdk']!;
      expect(sdkCmd.subcommands, contains('install'));
    });

    test('sdk command has list subcommand', () {
      final sdkCmd = commandRunner.commands['sdk']!;
      expect(sdkCmd.subcommands, contains('list'));
    });

    test('sdk command has remove subcommand', () {
      final sdkCmd = commandRunner.commands['sdk']!;
      expect(sdkCmd.subcommands, contains('remove'));
    });

    test('sdk install with no version arg returns usage exit code', () async {
      final result = await commandRunner.run(['sdk', 'install']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err('Please specify a version or channel to install.'),
      ).called(1);
    });

    test('sdk remove with no version arg returns usage exit code', () async {
      final result = await commandRunner.run(['sdk', 'remove']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err('Please specify a version to remove.'),
      ).called(1);
    });
  });
}
