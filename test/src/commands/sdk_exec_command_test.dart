import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';
import '../../helpers/test_helpers.dart';

void main() {
  group('sdk exec', () {
    final tempHome = TempHome();
    late Logger logger;
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      tempHome.setUp();
      final fixture = createTestCommandRunner();
      logger = fixture.logger;
      commandRunner = fixture.commandRunner;
    });

    tearDown(tempHome.tearDown);

    test('sdk exec subcommand is registered', () {
      final sdkCmd = commandRunner.commands['sdk']!;
      expect(sdkCmd.subcommands, contains('exec'));
    });

    test('no args returns usage exit code', () async {
      final result = await commandRunner.run(['sdk', 'exec']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err('Please specify a command to run.'),
      ).called(1);
    });

    test('no SDK configured returns usage exit code', () async {
      final result = await commandRunner.run(['sdk', 'exec', 'flutter']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          'No SDK version configured. '
          'Run "flutter_compile sdk global <version>" or '
          '"flutter_compile sdk use <version>" first.',
        ),
      ).called(1);
    });
  });
}
