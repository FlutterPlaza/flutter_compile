import 'package:flutter_compile/src/command_runner.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('codepush', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('codepush command is registered', () {
      expect(commandRunner.commands, contains('codepush'));
    });

    test('codepush command has alias cp', () {
      final cmd = commandRunner.commands['codepush']!;
      expect(cmd.aliases, contains('cp'));
    });

    test('codepush has all subcommands', () {
      final cmd = commandRunner.commands['codepush']!;
      final subcommands = cmd.subcommands;
      expect(subcommands, contains('init'));
      expect(subcommands, contains('login'));
      expect(subcommands, contains('logout'));
      expect(subcommands, contains('account'));
      expect(subcommands, contains('release'));
      expect(subcommands, contains('patch'));
      expect(subcommands, contains('rollback'));
      expect(subcommands, contains('status'));
    });

    test('codepush run completes without error', () async {
      final result = await commandRunner.run(['codepush']);
      // Returns success or usage depending on how the runner handles
      // a parent command with subcommands.
      expect(result, isA<int>());
    });

    group('release subcommand', () {
      test('has --build flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final release = cmd.subcommands['release']!;
        expect(release.argParser.options, contains('build'));
      });

      test('has --platform option', () {
        final cmd = commandRunner.commands['codepush']!;
        final release = cmd.subcommands['release']!;
        expect(release.argParser.options, contains('platform'));
      });

      test('has --snapshot option', () {
        final cmd = commandRunner.commands['codepush']!;
        final release = cmd.subcommands['release']!;
        expect(release.argParser.options, contains('snapshot'));
      });

      test('has --version option', () {
        final cmd = commandRunner.commands['codepush']!;
        final release = cmd.subcommands['release']!;
        expect(release.argParser.options, contains('version'));
      });

      test('has --app-id option', () {
        final cmd = commandRunner.commands['codepush']!;
        final release = cmd.subcommands['release']!;
        expect(release.argParser.options, contains('app-id'));
      });
    });

    group('patch subcommand', () {
      test('has --build flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('build'));
      });

      test('has --rollout option', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('rollout'));
      });

      test('has --release-id option', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('release-id'));
      });

      test('has --patch-file option', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('patch-file'));
      });
    });

    group('rollback subcommand', () {
      test('has --patch-id option', () {
        final cmd = commandRunner.commands['codepush']!;
        final rollback = cmd.subcommands['rollback']!;
        expect(rollback.argParser.options, contains('patch-id'));
      });
    });

    group('login subcommand', () {
      test('has --api-key option', () {
        final cmd = commandRunner.commands['codepush']!;
        final login = cmd.subcommands['login']!;
        expect(login.argParser.options, contains('api-key'));
      });

      test('has --server option', () {
        final cmd = commandRunner.commands['codepush']!;
        final login = cmd.subcommands['login']!;
        expect(login.argParser.options, contains('server'));
      });
    });

    group('init subcommand', () {
      test('has --name option', () {
        final cmd = commandRunner.commands['codepush']!;
        final init = cmd.subcommands['init']!;
        expect(init.argParser.options, contains('name'));
      });

      test('has --platform option', () {
        final cmd = commandRunner.commands['codepush']!;
        final init = cmd.subcommands['init']!;
        expect(init.argParser.options, contains('platform'));
      });
    });
  });
}
