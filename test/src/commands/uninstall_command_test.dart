import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('uninstall', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('uninstall command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('uninstall'));
    });

    test('uninstall command has aliases delete and remove', () {
      final uninstallCmd = commandRunner.commands['uninstall']!;
      expect(uninstallCmd.aliases, containsAll(['delete', 'remove']));
    });

    test('uninstall command has flutter subcommand', () {
      final uninstallCmd = commandRunner.commands['uninstall']!;
      expect(uninstallCmd.subcommands, contains('flutter'));
    });

    test('uninstall command has devtools subcommand', () {
      final uninstallCmd = commandRunner.commands['uninstall']!;
      expect(uninstallCmd.subcommands, contains('devtools'));
    });

    test('uninstall command has engine subcommand', () {
      final uninstallCmd = commandRunner.commands['uninstall']!;
      expect(uninstallCmd.subcommands, contains('engine'));
    });

    test('uninstall with no subcommand returns usage exit code', () async {
      final result = await commandRunner.run(['uninstall']);
      expect(result, equals(ExitCode.usage.code));
    });
  });
}
