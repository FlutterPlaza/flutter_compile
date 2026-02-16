import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('run', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('run command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('run'));
    });

    test('run command has alias r', () {
      final runCmd = commandRunner.commands['run']!;
      expect(runCmd.aliases, contains('r'));
    });

    test('run command accepts expected options', () {
      final runCmd = commandRunner.commands['run']!;
      final options = runCmd.argParser.options;
      expect(options, contains('platform'));
      expect(options, contains('cpu'));
      expect(options, contains('mode'));
      expect(options, contains('unoptimized'));
      expect(options, contains('simulator'));
    });
  });
}
