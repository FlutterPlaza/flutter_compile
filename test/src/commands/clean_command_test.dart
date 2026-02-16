import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_updater/pub_updater.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockPubUpdater extends Mock implements PubUpdater {}

void main() {
  group('clean', () {
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
