import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_release.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

class MockProgress extends Mock implements Progress {}

class MockBuildService extends Mock implements CodePushBuildService {}

/// Exposes the command with parsed args so the REAL flag read at the
/// `allowExtendable:` call site executes against a real [ArgResults]
/// (direct calls otherwise see a null `argResults`, and the `?? true`
/// default would mask a flag that silently became a no-op).
class ParsedArgsReleaseCommand extends CodePushReleaseSubCommand {
  ParsedArgsReleaseCommand(super.logger, {super.buildService});

  ArgResults? parsedArgs;

  @override
  ArgResults? get argResults => parsedArgs;
}

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

    test('--no-extendable-widgets reaches the spec writer as false', () async {
      final cmd = ParsedArgsReleaseCommand(logger, buildService: buildService);
      cmd.parsedArgs = cmd.argParser.parse(['--no-extendable-widgets']);
      when(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          allowExtendable: any(named: 'allowExtendable'),
          onSkip: any(named: 'onSkip'),
        ),
      ).thenReturn(
        (
          specPath: '/spec/dynamic_interface.yaml',
          appCount: 1,
          flutterCount: 2
        ),
      );
      final freeze = await cmd.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(freeze, isNotNull);
      verify(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          allowExtendable: false,
          onSkip: any(named: 'onSkip'),
        ),
      ).called(1);
      // Disabling the guarding costs a device crash on the first
      // widget-adding patch; it must be loud, not --verbose-only.
      verify(
        () => logger.warn(any(that: contains('--no-extendable-widgets'))),
      ).called(1);
    });

    test('default arg parse keeps extendable guarding on', () async {
      final cmd = ParsedArgsReleaseCommand(logger, buildService: buildService);
      cmd.parsedArgs = cmd.argParser.parse([]);
      when(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          allowExtendable: any(named: 'allowExtendable'),
          onSkip: any(named: 'onSkip'),
        ),
      ).thenReturn(
        (
          specPath: '/spec/dynamic_interface.yaml',
          appCount: 1,
          flutterCount: 2
        ),
      );
      await cmd.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      verify(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          allowExtendable: true,
          onSkip: any(named: 'onSkip'),
        ),
      ).called(1);
      verifyNever(() => logger.warn(any()));
    });

    test('unwritable project root => typed exception before any compile',
        () async {
      if (Platform.isWindows) {
        markTestSkipped('chmod semantics are POSIX-only');
        return;
      }
      Process.runSync('chmod', ['555', tmp.path]);
      addTearDown(() => Process.runSync('chmod', ['755', tmp.path]));
      try {
        // Root (containers) ignores mode bits; then there is nothing to
        // assert here.
        File('${tmp.path}/probe').writeAsStringSync('x');
        markTestSkipped('running with privileges that bypass file modes');
        return;
      } on FileSystemException {
        // Expected: the directory really is unwritable.
      }
      await expectLater(
        () => command.prepareIosInterfaceFreeze(
          buildService,
          projectRootOverride: tmp.path,
        ),
        throwsA(
          isA<FlutterCompileException>().having(
            (e) => e.message,
            'message',
            contains('Check permissions'),
          ),
        ),
      );
      verify(
        () => logger.err(any(that: contains('Check permissions'))),
      ).called(1);
      verifyNever(
        () => buildService.discoverCompileClosure(
          targetPath: any(named: 'targetPath'),
          workDirPath: any(named: 'workDirPath'),
        ),
      );
    });

    test('null spec mapping fails the spinner with the report guidance',
        () async {
      when(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          allowExtendable: any(named: 'allowExtendable'),
          onSkip: any(named: 'onSkip'),
        ),
      ).thenReturn(null);
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(freeze, isNull);
      verify(
        () => progress.fail('Could not map the app libraries for the release'),
      ).called(1);
      verify(
        () => logger.err(any(that: contains('Please report this'))),
      ).called(1);
    });

    test('comma in the spec path the front end would receive refuses',
        () async {
      when(
        () => buildService.writeIosInterfaceFreezeSpec(
          closurePaths: any(named: 'closurePaths'),
          projectRoot: any(named: 'projectRoot'),
          packageName: any(named: 'packageName'),
          specDirPath: any(named: 'specDirPath'),
          allowExtendable: any(named: 'allowExtendable'),
          onSkip: any(named: 'onSkip'),
        ),
      ).thenReturn(
        (
          specPath: '/spec,dir/dynamic_interface.yaml',
          appCount: 1,
          flutterCount: 2
        ),
      );
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(freeze, isNull);
      verify(() => progress.fail('Could not use the interface spec path'))
          .called(1);
      verify(
        () => logger.err(any(that: contains('comma-free'))),
      ).called(1);
    });

    test('unreadable pubspec gets the actionable error, not a raw throw',
        () async {
      if (Platform.isWindows) {
        markTestSkipped('chmod semantics are POSIX-only');
        return;
      }
      Process.runSync('chmod', ['000', '${tmp.path}/pubspec.yaml']);
      addTearDown(
        () => Process.runSync('chmod', ['644', '${tmp.path}/pubspec.yaml']),
      );
      try {
        // Root (containers) ignores mode bits; then there is nothing to
        // assert here.
        File('${tmp.path}/pubspec.yaml').readAsStringSync();
        markTestSkipped('running with privileges that bypass file modes');
        return;
      } on FileSystemException {
        // Expected: the file really is unreadable.
      }
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(freeze, isNull);
      verify(
        () => logger.err(any(that: contains('package name'))),
      ).called(1);
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
