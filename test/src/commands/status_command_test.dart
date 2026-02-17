import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('status', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('status command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('status'));
    });

    test('status accepts --json flag', () {
      final statusCmd = commandRunner.commands['status']!;
      expect(statusCmd.argParser.options, contains('json'));
    });

    test('status command has alias st', () {
      final statusCmd = commandRunner.commands['status']!;
      expect(statusCmd.aliases, contains('st'));
    });
  });
}
