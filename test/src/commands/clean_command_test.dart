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
  group('clean', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
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

  group('clean with temp home', () {
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

    test('clean reports engine not configured when no rc file', () async {
      final result = await commandRunner.run(['clean']);
      expect(result, equals(ExitCode.success.code));
      verify(
        () => logger.info(
          'Engine not configured. '
          'Run `flutter_compile install engine` first.',
        ),
      ).called(1);
    });

    test('clean reports no out/ directory when engine has no builds', () async {
      // Set up engine path in rc config
      final enginePath = '${tempHome.path}${Constants.engineInstallPath}';
      Directory(enginePath).createSync(recursive: true);
      final rcFile = File('${tempHome.path}/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(
        rcFile,
        RunCommandKey.engine.key,
        enginePath,
      );

      final result = await commandRunner.run(['clean']);
      expect(result, equals(ExitCode.success.code));
      verify(
        () => logger.info('No out/ directory found at $enginePath/src/out.'),
      ).called(1);
    });
  });
}
