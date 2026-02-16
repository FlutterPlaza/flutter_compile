import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('test', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('test command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('test'));
    });

    test('test command has alias t', () {
      final testCmd = commandRunner.commands['test']!;
      expect(testCmd.aliases, contains('t'));
    });

    test('test command accepts expected options', () {
      final testCmd = commandRunner.commands['test']!;
      final options = testCmd.argParser.options;
      expect(options, contains('platform'));
      expect(options, contains('cpu'));
      expect(options, contains('mode'));
      expect(options, contains('unoptimized'));
      expect(options, contains('simulator'));
    });
  });
}
