import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pub_updater/pub_updater.dart';

class MockLogger extends Mock implements Logger {}

class MockPubUpdater extends Mock implements PubUpdater {}

class MockProgress extends Mock implements Progress {}

({
  Logger logger,
  PubUpdater pubUpdater,
  FlutterCompileCommandRunner commandRunner,
})
createTestCommandRunner() {
  final logger = MockLogger();
  final pubUpdater = MockPubUpdater();

  when(
    () => pubUpdater.getLatestVersion(any()),
  ).thenAnswer((_) async => packageVersion);

  final commandRunner = FlutterCompileCommandRunner(
    logger: logger,
    pubUpdater: pubUpdater,
  );

  return (logger: logger, pubUpdater: pubUpdater, commandRunner: commandRunner);
}
