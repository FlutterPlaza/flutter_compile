import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('sdk use', () {
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;
    });

    test('sdk use subcommand is registered', () {
      final sdkCmd = commandRunner.commands['sdk']!;
      expect(sdkCmd.subcommands, contains('use'));
    });

    test('no args and no .flutter-version shows info message', () async {
      final result = await commandRunner.run(['sdk', 'use']);
      expect(result, equals(ExitCode.success.code));
      verify(
        () => logger.info(
          'No project SDK version set '
          '(no .flutter-version found).',
        ),
      ).called(1);
    });

    test('non-installed version returns usage exit code', () async {
      final result = await commandRunner.run([
        'sdk',
        'use',
        'non_existent_version',
      ]);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          'Flutter SDK "non_existent_version" is not installed. '
          'Run "flutter_compile sdk install non_existent_version" first.',
        ),
      ).called(1);
    });
  });
}
