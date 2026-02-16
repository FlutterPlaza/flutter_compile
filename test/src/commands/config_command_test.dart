import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_updater/pub_updater.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockPubUpdater extends Mock implements PubUpdater {}

void main() {
  group('config', () {
    late Logger logger;
    late PubUpdater pubUpdater;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      logger = _MockLogger();
      pubUpdater = _MockPubUpdater();

      when(
        () => pubUpdater.getLatestVersion(any()),
      ).thenAnswer((_) async => packageVersion);

      commandRunner = FlutterCompileCommandRunner(
        logger: logger,
        pubUpdater: pubUpdater,
      );
    });

    test('config command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('config'));
    });

    test('config command has alias cf', () {
      final configCmd = commandRunner.commands['config']!;
      expect(configCmd.aliases, contains('cf'));
    });

    test('config command has list, get, set subcommands', () {
      final configCmd = commandRunner.commands['config']!;
      final subcommands = configCmd.subcommands;
      expect(subcommands, contains('list'));
      expect(subcommands, contains('get'));
      expect(subcommands, contains('set'));
    });
  });
}
