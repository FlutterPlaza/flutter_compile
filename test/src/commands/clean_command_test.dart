import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('clean', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('clean command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('clean'));
    });

    test('clean command has alias c', () {
      final cleanCmd = commandRunner.commands['clean']!;
      expect(cleanCmd.aliases, contains('c'));
    });

    test('clean command accepts --all flag', () {
      final cleanCmd = commandRunner.commands['clean']!;
      final options = cleanCmd.argParser.options;
      expect(options, contains('all'));
    });
  });
}
