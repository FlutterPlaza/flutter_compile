import 'dart:io';

import 'package:flutter_compile/src/commands/codepush_commands/_codepush_release.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

class MockProgress extends Mock implements Progress {}

class MockBuildService extends Mock implements CodePushBuildService {}

void main() {
  group('prepareIosInterfaceFreeze failure surfacing', () {
    late Directory tmp;
    late Directory previousCwd;
    late MockLogger logger;
    late MockProgress progress;
    late MockBuildService buildService;
    late CodePushReleaseSubCommand command;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('freeze_cmd_test');
      previousCwd = Directory.current;
      Directory.current = tmp;
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      logger = MockLogger();
      progress = MockProgress();
      when(() => logger.progress(any())).thenReturn(progress);
      when(() => logger.detail(any())).thenReturn(null);
      when(() => logger.err(any())).thenReturn(null);
      when(() => logger.warn(any())).thenReturn(null);
      buildService = MockBuildService();
      when(() => buildService.findFlutterRootForProbe())
          .thenReturn('/fake/flutter');
      when(() => buildService.frontendSupportsFreeze(any())).thenReturn(true);
      when(
        () => buildService.discoverCompileClosure(
          targetPath: any(named: 'targetPath'),
          workDirPath: any(named: 'workDirPath'),
        ),
      ).thenAnswer((_) async => {'${tmp.path}/lib/main.dart'});
      command = CodePushReleaseSubCommand(logger, buildService: buildService);
    });

    tearDown(() {
      Directory.current = previousCwd;
      tmp.deleteSync(recursive: true);
    });

    test('spec-write failure fails the spinner and logs the guidance',
        () async {
      when(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          onSkip: any(named: 'onSkip'),
        ),
      ).thenThrow(
        const FlutterCompileException(
          'Could not write spec (read-only). Check permissions and free '
          'space on the build directory.',
        ),
      );

      await expectLater(
        () => command.prepareIosInterfaceFreeze(buildService),
        throwsA(isA<FlutterCompileException>()),
      );
      verify(() => progress.fail('Could not write the interface spec'))
          .called(1);
      verify(
        () => logger.err(any(that: contains('Check permissions'))),
      ).called(1);
    });

    test('unsupported front-end fails before any compile', () async {
      when(() => buildService.frontendSupportsFreeze(any())).thenReturn(false);
      final result = await command.prepareIosInterfaceFreeze(buildService);
      expect(result, isNull);
      verify(
        () => logger.err(any(that: contains('--no-interface-freeze'))),
      ).called(1);
      verifyNever(
        () => buildService.discoverCompileClosure(
          targetPath: any(named: 'targetPath'),
          workDirPath: any(named: 'workDirPath'),
        ),
      );
    });
  });
}
