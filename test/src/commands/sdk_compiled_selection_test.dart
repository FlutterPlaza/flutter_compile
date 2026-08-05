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

  /// Creates a fake contributor checkout with a `bin/flutter` marker.
  void createFakeCheckout() {
    final bin = Directory(
      '${tempHome.path}${Constants.flutterCompileInstallPath}/bin',
    )..createSync(recursive: true);
    File('${bin.path}/flutter').createSync();
  }

  group('normalizeSdkName', () {
    test('maps the engine alias to compiled and trims whitespace', () {
      expect(F.normalizeSdkName('engine'), equals('compiled'));
      expect(F.normalizeSdkName(' engine '), equals('compiled'));
      expect(F.normalizeSdkName('compiled'), equals('compiled'));
      expect(F.normalizeSdkName(' 3.41.6 '), equals('3.41.6'));
    });
  });

  group('getSdkPath for the contributor environment', () {
    test('resolves compiled and engine to the checkout when present', () {
      createFakeCheckout();
      final expected = '${tempHome.path}${Constants.flutterCompileInstallPath}';
      expect(F.getSdkPath('compiled'), equals(expected));
      expect(F.getSdkPath('engine'), equals(expected));
      expect(F.isSdkInstalled('compiled'), isTrue);
    });

    test('returns null when the checkout is absent', () {
      expect(F.getSdkPath('compiled'), isNull);
      expect(F.isSdkInstalled('compiled'), isFalse);
    });
  });

  group('sdk use compiled', () {
    late Directory previousCwd;
    late Directory projectDir;

    setUp(() {
      previousCwd = Directory.current;
      projectDir = Directory.systemTemp.createTempSync('fc_project_');
      Directory.current = projectDir;
    });

    tearDown(() {
      Directory.current = previousCwd;
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });

    test('pins the canonical name for the engine alias and prints the caveat',
        () async {
      createFakeCheckout();
      final result = await commandRunner.run(['sdk', 'use', 'engine']);
      expect(result, equals(ExitCode.success.code));

      final pin = File('${projectDir.path}/${Constants.flutterVersionFile}');
      expect(pin.existsSync(), isTrue);
      expect(pin.readAsStringSync().trim(), equals('compiled'));
      verify(() => logger.info(Constants.compiledSdkCaveat)).called(1);
    });

    test('errors with the install-flutter hint when checkout is absent',
        () async {
      final result = await commandRunner.run(['sdk', 'use', 'compiled']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          'The contributor environment is not installed. '
          'Run "flutter_compile install flutter" first.',
        ),
      ).called(1);
    });
  });

  group('sdk global compiled', () {
    test(
      'sets the canonical name and prints the caveat when checkout is present',
      () async {
        createFakeCheckout();
        final result = await commandRunner.run(['sdk', 'global', 'engine']);
        expect(result, equals(ExitCode.success.code));
        verify(() => logger.info(Constants.compiledSdkCaveat)).called(1);

        final rc = File('${tempHome.path}/.flutter_compilerc');
        expect(rc.existsSync(), isTrue);
        expect(rc.readAsStringSync(), contains('global_sdk_version:compiled'));
      },
      skip: Platform.isWindows
          ? 'default-symlink creation needs elevated privileges on Windows '
              'runners'
          : false,
    );

    test('errors with the install-flutter hint when checkout is absent',
        () async {
      final result = await commandRunner.run(['sdk', 'global', 'engine']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          'The contributor environment is not installed. '
          'Run "flutter_compile install flutter" first.',
        ),
      ).called(1);
    });
  });

  group('sdk exec compiled', () {
    late Directory previousCwd;
    late Directory projectDir;

    setUp(() {
      previousCwd = Directory.current;
      projectDir = Directory.systemTemp.createTempSync('fc_exec_');
      Directory.current = projectDir;
    });

    tearDown(() {
      Directory.current = previousCwd;
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });

    test(
        'errors with the install-flutter hint when the pinned checkout '
        'is absent', () async {
      await File('${projectDir.path}/${Constants.flutterVersionFile}')
          .writeAsString('compiled\n');
      final result = await commandRunner.run(['sdk', 'exec', 'flutter']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          'The contributor environment is not installed. '
          'Run "flutter_compile install flutter" first.',
        ),
      ).called(1);
    });

    test('normalizes a hand-written engine pin', () async {
      await File('${projectDir.path}/${Constants.flutterVersionFile}')
          .writeAsString('engine\n');
      final result = await commandRunner.run(['sdk', 'exec', 'flutter']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          'The contributor environment is not installed. '
          'Run "flutter_compile install flutter" first.',
        ),
      ).called(1);
    });
  });

  group('sdk remove compiled', () {
    test('refuses to remove the contributor environment', () async {
      createFakeCheckout();
      final result = await commandRunner.run(['sdk', 'remove', 'compiled']);
      expect(result, equals(ExitCode.usage.code));
      verify(
        () => logger.err(
          '"compiled" is the contributor environment '
          'managed by "flutter_compile install flutter" / '
          '"flutter_compile uninstall flutter" — '
          'sdk remove does not manage it.',
        ),
      ).called(1);
      // The checkout must still exist.
      expect(
        Directory(
          '${tempHome.path}${Constants.flutterCompileInstallPath}',
        ).existsSync(),
        isTrue,
      );
    });

    test('refuses the engine alias too', () async {
      createFakeCheckout();
      final result = await commandRunner.run(['sdk', 'remove', 'engine']);
      expect(result, equals(ExitCode.usage.code));
    });
  });
}
