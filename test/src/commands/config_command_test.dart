import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

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

    test('config command has list, get, set subcommands', () {
      final configCmd = commandRunner.commands['config']!;
      final subcommands = configCmd.subcommands;
      expect(subcommands, contains('list'));
      expect(subcommands, contains('get'));
      expect(subcommands, contains('set'));
    });
  });
}
