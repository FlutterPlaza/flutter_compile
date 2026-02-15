import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_updater/pub_updater.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockPubUpdater extends Mock implements PubUpdater {}

void main() {
  group('doctor', () {
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

    test('runs without throwing', () async {
      final result = await commandRunner.run(['doctor']);
      expect(result, equals(ExitCode.success.code));
    });

    test('prints header', () async {
      await commandRunner.run(['doctor']);
      verify(() => logger.info('Flutter Compile Doctor\n')).called(1);
    });
  });
}
