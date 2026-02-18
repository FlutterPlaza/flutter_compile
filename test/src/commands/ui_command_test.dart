import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('ui command', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('command is registered with name ui', () {
      expect(commandRunner.commands, contains('ui'));
    });

    test('description contains terminal UI', () {
      final cmd = commandRunner.commands['ui']!;
      expect(cmd.description, contains('terminal UI'));
    });
  });
}
