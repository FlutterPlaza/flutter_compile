import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('switch', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('switch command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('switch'));
    });

    test('switch command has alias s', () {
      final switchCmd = commandRunner.commands['switch']!;
      expect(switchCmd.aliases, contains('s'));
    });
  });
}
