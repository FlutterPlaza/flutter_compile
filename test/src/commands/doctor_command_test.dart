import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('doctor', () {
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;
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
