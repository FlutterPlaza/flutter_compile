import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('sdk global', () {
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;
    });

    test('sdk global subcommand is registered', () {
      final sdkCmd = commandRunner.commands['sdk']!;
      expect(sdkCmd.subcommands, contains('global'));
    });

    test('no args and no global set shows info message', () async {
      final result = await commandRunner.run(['sdk', 'global']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('No global SDK version set.')).called(1);
    });

    test('non-installed version returns usage exit code', () async {
      final result =
          await commandRunner.run(['sdk', 'global', 'non_existent_version']);
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
