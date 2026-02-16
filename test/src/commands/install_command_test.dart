import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('install', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('install command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('install'));
    });

    test('install command has alias i', () {
      final installCmd = commandRunner.commands['install']!;
      expect(installCmd.aliases, contains('i'));
    });

    test('install command has flutter subcommand', () {
      final installCmd = commandRunner.commands['install']!;
      expect(installCmd.subcommands, contains('flutter'));
    });

    test('install command has devtools subcommand', () {
      final installCmd = commandRunner.commands['install']!;
      expect(installCmd.subcommands, contains('devtools'));
    });

    test('install command has engine subcommand', () {
      final installCmd = commandRunner.commands['install']!;
      expect(installCmd.subcommands, contains('engine'));
    });

    test('install with no subcommand returns usage exit code', () async {
      final result = await commandRunner.run(['install']);
      expect(result, equals(ExitCode.usage.code));
    });
  });
}
