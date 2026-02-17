import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('sync', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('sync command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('sync'));
    });

    test('sync command has alias sy', () {
      final syncCmd = commandRunner.commands['sync']!;
      expect(syncCmd.aliases, contains('sy'));
    });

    test('sync command has flutter subcommand', () {
      final syncCmd = commandRunner.commands['sync']!;
      expect(syncCmd.subcommands, contains('flutter'));
    });

    test('sync command has engine subcommand', () {
      final syncCmd = commandRunner.commands['sync']!;
      expect(syncCmd.subcommands, contains('engine'));
    });

    test('sync command has devtools subcommand', () {
      final syncCmd = commandRunner.commands['sync']!;
      expect(syncCmd.subcommands, contains('devtools'));
    });
  });
}
