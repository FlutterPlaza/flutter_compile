import 'dart:io';

import 'package:flutter_compile/src/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';
import '../../helpers/test_helpers.dart';

void main() {
  group('status', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('status command is registered', () {
      final commands = commandRunner.commands;
      expect(commands, contains('status'));
    });

    test('status accepts --json flag', () {
      final statusCmd = commandRunner.commands['status']!;
      expect(statusCmd.argParser.options, contains('json'));
    });

    test('status command has alias st', () {
      final statusCmd = commandRunner.commands['status']!;
      expect(statusCmd.aliases, contains('st'));
    });
  });

  group('status with temp home', () {
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

    test('status reports engine not configured when no rc file', () async {
      final result = await commandRunner.run(['status']);
      expect(result, equals(ExitCode.success.code));
      verify(
        () => logger.info(
          'Engine not configured. '
          'Run `flutter_compile install engine` first.',
        ),
      ).called(1);
    });

    test('status --json reports configured: false when no rc file', () async {
      final result = await commandRunner.run(['status', '--json']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('{"configured":false}')).called(1);
    });

    test('status shows engine info when configured', () async {
      final enginePath = '${tempHome.path}${Constants.engineInstallPath}';
      Directory('$enginePath/src').createSync(recursive: true);
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(
        rcFile,
        RunCommandKey.engine.key,
        enginePath,
      );

      final result = await commandRunner.run(['status']);
      expect(result, equals(ExitCode.success.code));
      verify(() => logger.info('Engine path: $enginePath')).called(1);
      verify(() => logger.info('Available builds: (none)')).called(1);
    });
  });
}
