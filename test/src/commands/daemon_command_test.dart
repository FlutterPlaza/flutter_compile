import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('daemon command', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('command is registered with name daemon', () {
      expect(commandRunner.commands, contains('daemon'));
    });

    test('has no aliases', () {
      final cmd = commandRunner.commands['daemon']!;
      expect(cmd.aliases, isEmpty);
    });

    test('description contains JSON-RPC', () {
      final cmd = commandRunner.commands['daemon']!;
      expect(cmd.description, contains('JSON-RPC'));
    });
  });
}
