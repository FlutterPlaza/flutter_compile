import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_updater/pub_updater.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockPubUpdater extends Mock implements PubUpdater {}

void main() {
  group('test', () {
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

    test('test command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('test'));
    });

    test('test command has alias t', () {
      final testCmd = commandRunner.commands['test']!;
      expect(testCmd.aliases, contains('t'));
    });

    test('test command accepts expected options', () {
      final testCmd = commandRunner.commands['test']!;
      final options = testCmd.argParser.options;
      expect(options, contains('platform'));
      expect(options, contains('cpu'));
      expect(options, contains('mode'));
      expect(options, contains('unoptimized'));
      expect(options, contains('simulator'));
    });
  });
}
