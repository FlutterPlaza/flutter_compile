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
    late MockLogger logger;
    late MockProgress progress;
    late MockBuildService buildService;
    late CodePushReleaseSubCommand command;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('freeze_cmd_test');
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

    tearDown(() => tmp.deleteSync(recursive: true));

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
        () => command.prepareIosInterfaceFreeze(
          buildService,
          projectRootOverride: tmp.path,
        ),
        throwsA(isA<FlutterCompileException>()),
      );
      verify(() => progress.fail('Could not write the interface spec'))
          .called(1);
      verify(
        () => logger.err(any(that: contains('Check permissions'))),
      ).called(1);
    });

    test('success path returns a closure that injects the spec path', () async {
      when(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          onSkip: any(named: 'onSkip'),
        ),
      ).thenReturn(
        (
          specPath: '/spec/dynamic_interface.yaml',
          appCount: 1,
          flutterCount: 2
        ),
      );
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      final args = freeze!(['--dart-define=A=1']);
      expect(
        args.join(' '),
        contains('--dynamic-interface=/spec/dynamic_interface.yaml'),
      );
    });

    test('frontendSupportsFreeze delegates to the real probe', () {
      final real = CodePushBuildService(logger: logger);
      final root = Directory.systemTemp.createTempSync('probe_delegate');
      addTearDown(() => root.deleteSync(recursive: true));
      File(
        '${root.path}/bin/cache/dart-sdk/bin/snapshots/'
        'frontend_server_aot.dart.snapshot',
      )
        ..createSync(recursive: true)
        ..writeAsBytesSync('dynamic-interface'.codeUnits);
      expect(real.frontendSupportsFreeze(root.path), true);
      expect(real.frontendSupportsFreeze('/nope'), false);
    });

    test('unsupported front-end fails before any compile', () async {
      when(() => buildService.frontendSupportsFreeze(any())).thenReturn(false);
      final result = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
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
