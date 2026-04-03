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
      expect(subcommands, contains('setup'));
      expect(subcommands, contains('apps'));
      expect(subcommands, contains('billing'));
      expect(subcommands, contains('seed-secrets'));
    });

    test('codepush run completes without error', () async {
      final result = await commandRunner.run(['codepush']);
      expect(result, isA<int>());
    });

    group('setup subcommand', () {
      test('has --flutter-version option', () {
        final cmd = commandRunner.commands['codepush']!;
        final setup = cmd.subcommands['setup']!;
        expect(setup.argParser.options, contains('flutter-version'));
      });

      test('has --platform option', () {
        final cmd = commandRunner.commands['codepush']!;
        final setup = cmd.subcommands['setup']!;
        expect(setup.argParser.options, contains('platform'));
      });

      test('has --force flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final setup = cmd.subcommands['setup']!;
        expect(setup.argParser.options, contains('force'));
      });

      test('has --list-versions flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final setup = cmd.subcommands['setup']!;
        expect(setup.argParser.options, contains('list-versions'));
      });

      test('has --cleanup flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final setup = cmd.subcommands['setup']!;
        expect(setup.argParser.options, contains('cleanup'));
      });
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

      test('has --deterministic flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final release = cmd.subcommands['release']!;
        expect(release.argParser.options, contains('deterministic'));
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

      test('has --channel option', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('channel'));
      });

      test('has --signing-key option', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('signing-key'));
      });

      test('has --baseline option', () {
        final cmd = commandRunner.commands['codepush']!;
        final patch = cmd.subcommands['patch']!;
        expect(patch.argParser.options, contains('baseline'));
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

    group('apps subcommand', () {
      test('is registered', () {
        final cmd = commandRunner.commands['codepush']!;
        expect(cmd.subcommands, contains('apps'));
      });

      test('has list subcommand', () {
        final cmd = commandRunner.commands['codepush']!;
        final apps = cmd.subcommands['apps']!;
        expect(apps.subcommands, contains('list'));
      });

      test('has create subcommand', () {
        final cmd = commandRunner.commands['codepush']!;
        final apps = cmd.subcommands['apps']!;
        expect(apps.subcommands, contains('create'));
      });

      test('create has --name option', () {
        final cmd = commandRunner.commands['codepush']!;
        final apps = cmd.subcommands['apps']!;
        final create = apps.subcommands['create']!;
        expect(create.argParser.options, contains('name'));
      });

      test('create has --platform option', () {
        final cmd = commandRunner.commands['codepush']!;
        final apps = cmd.subcommands['apps']!;
        final create = apps.subcommands['create']!;
        expect(create.argParser.options, contains('platform'));
      });
    });

    group('billing subcommand', () {
      test('is registered', () {
        final cmd = commandRunner.commands['codepush']!;
        expect(cmd.subcommands, contains('billing'));
      });

      test('has usage subcommand', () {
        final cmd = commandRunner.commands['codepush']!;
        final billing = cmd.subcommands['billing']!;
        expect(billing.subcommands, contains('usage'));
      });
    });

    group('seed-secrets subcommand', () {
      test('is registered', () {
        final cmd = commandRunner.commands['codepush']!;
        expect(cmd.subcommands, contains('seed-secrets'));
      });

      test('has --env-file option', () {
        final cmd = commandRunner.commands['codepush']!;
        final seeds = cmd.subcommands['seed-secrets']!;
        expect(seeds.argParser.options, contains('env-file'));
      });

      test('has --project option', () {
        final cmd = commandRunner.commands['codepush']!;
        final seeds = cmd.subcommands['seed-secrets']!;
        expect(seeds.argParser.options, contains('project'));
      });

      test('has --dry-run flag', () {
        final cmd = commandRunner.commands['codepush']!;
        final seeds = cmd.subcommands['seed-secrets']!;
        expect(seeds.argParser.options, contains('dry-run'));
      });
    });

    group('status subcommand', () {
      test('has --app-id option', () {
        final cmd = commandRunner.commands['codepush']!;
        final status = cmd.subcommands['status']!;
        expect(status.argParser.options, contains('app-id'));
      });
    });
  });
}
