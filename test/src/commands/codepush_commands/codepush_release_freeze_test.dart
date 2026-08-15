import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_release.dart';
import 'package:flutter_compile/src/shared/codepush_archive_service.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/interface_freeze_constants.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

class MockProgress extends Mock implements Progress {}

class MockBuildService extends Mock implements CodePushBuildService {}

class MockArchiveService extends Mock implements CodePushArchiveService {}

/// The real service except the expensive probe/compile seams, so the
/// command's composed spec directory feeds the REAL writer and the
/// artifact demonstrably lands where the front end is told it will.
class FakeClosureBuildService extends CodePushBuildService {
  FakeClosureBuildService({required super.logger, required this.closure});

  final Set<String> closure;

  @override
  String? findFlutterRootForProbe() => '/fake/flutter';

  @override
  bool frontendSupportsFreeze(String flutterRoot) => true;

  @override
  Future<Set<String>?> discoverCompileClosure({
    required String targetPath,
    required String workDirPath,
    String? flutterRootOverride,
    String? projectRootOverride,
    ProcessResult Function(String executable, List<String> args)? runProcess,
  }) async =>
      closure;
}

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
          projectRootOverride: any(named: 'projectRootOverride'),
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
          flutterCount: 2,
          extendable: true,
          specChange: InterfaceSpecChange.unchanged
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
      // The archive step reads this to claim only THIS run's spec.
      expect(
        command.writtenInterfaceSpec,
        (
          path: '/spec/dynamic_interface.yaml',
          reportPath: '${tmp.path}/build/codepush/'
              'dynamic_interface_report.json',
          extendable: true,
          specChange: InterfaceSpecChange.unchanged
        ),
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
          flutterCount: 2,
          extendable: false,
          specChange: InterfaceSpecChange.unchanged
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
      // The acknowledged opt-out proceeds, and the green line says so.
      verify(
        () => progress.complete(any(that: contains('widget guarding off'))),
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
          flutterCount: 2,
          extendable: true,
          specChange: InterfaceSpecChange.unchanged
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
      final commaSpec = File('${tmp.path}/spec,dir/dynamic_interface.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('callable:\n');
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
          specPath: commaSpec.path,
          appCount: 1,
          flutterCount: 2,
          extendable: true,
          specChange: InterfaceSpecChange.unchanged
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
      // No artifact may suggest a refused build used it.
      expect(commaSpec.existsSync(), false);
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

    test('gate miss without the opt-out is a hard stop with guidance',
        () async {
      // A real file, so the abort's clean-up of the just-written spec
      // is observable.
      final orphanSpec = File('${tmp.path}/dynamic_interface.yaml')
        ..writeAsStringSync('callable:\n');
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
          specPath: orphanSpec.path,
          appCount: 1,
          flutterCount: 0,
          extendable: false,
          specChange: InterfaceSpecChange.unchanged
        ),
      );
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(freeze, isNull);
      // A failed freeze must leave nothing for the archive to claim —
      // neither the field nor the just-written file.
      expect(command.writtenInterfaceSpec, isNull);
      expect(orphanSpec.existsSync(), false);
      verify(
        () =>
            progress.fail('Widget base classes could not be marked extendable'),
      ).called(1);
      // The guidance names the library the gate searched for — the
      // datum that makes a "report this" report actionable.
      verify(
        () => logger.err(
          any(
            that: allOf(
              contains('--no-extendable-widgets'),
              contains(CodePushBuildService.kIosExtendableFrameworkLibrary),
            ),
          ),
        ),
      ).called(1);
    });

    test('real writer lands the spec in the command-composed directory',
        () async {
      Directory('${tmp.path}/lib').createSync(recursive: true);
      File('${tmp.path}/lib/main.dart').writeAsStringSync('void main() {}');
      final real = FakeClosureBuildService(
        logger: logger,
        closure: {
          '${tmp.path}/lib/main.dart',
          '/sdk/packages/flutter/lib/src/widgets/framework.dart',
        },
      );
      final cmd = CodePushReleaseSubCommand(logger, buildService: real);
      final freeze = await cmd.prepareIosInterfaceFreeze(
        real,
        projectRootOverride: tmp.path,
      );
      final specPath = cmd.writtenInterfaceSpec!.path;
      expect(
        specPath,
        matches(
          RegExp(r'build/codepush/dynamic_interface_[0-9a-f]{16}\.yaml$'),
        ),
      );
      final specFile = File(specPath);
      expect(specFile.existsSync(), true);
      expect(specFile.readAsStringSync(), contains('extendable:'));
      final args = freeze!(<String>[]).join(' ');
      expect(args, contains('--dynamic-interface=$specPath'));
      expect(
        args,
        contains('${tmp.path}/build/codepush/dynamic_interface_report.json'),
      );
      expect(cmd.writtenInterfaceSpec!.extendable, true);
    });

    test('checkInterfaceReportAfterBuild warns only when no report exists', () {
      // No freeze applied: silent no-op.
      command.checkInterfaceReportAfterBuild();
      expect(command.interfaceReportObservedAfterBuild, false);
      verifyNever(() => logger.warn(any()));

      final report = File('${tmp.path}/dynamic_interface_report.json');
      // Unchanged spec: the missing report leads with the benign
      // reuse explanation.
      command.writtenInterfaceSpec = (
        path: '${tmp.path}/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: report.path,
        extendable: true,
        specChange: InterfaceSpecChange.unchanged
      );
      command.checkInterfaceReportAfterBuild();
      expect(command.interfaceReportObservedAfterBuild, false);
      // The healthy repeat-build case must NOT warn — detail only.
      verify(
        () => logger.detail(
          any(
            that: allOf(
              contains('No interface report was found at'),
              contains(report.path),
              contains('unchanged compile was reused'),
            ),
          ),
        ),
      ).called(1);
      verifyNever(() => logger.warn(any()));

      // Changed spec: reuse cannot explain it — lead with the
      // SDK-drift candidate instead.
      command.writtenInterfaceSpec = (
        path: '${tmp.path}/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: report.path,
        extendable: true,
        specChange: InterfaceSpecChange.changed
      );
      command.checkInterfaceReportAfterBuild();
      verify(
        () => logger.warn(
          any(
            that: allOf(
              contains('the interface spec changed this run'),
              contains('SDK is newer'),
            ),
          ),
        ),
      ).called(1);

      // Unknown (nothing to compare against): genuinely neutral
      // wording, asserting neither reuse nor a fresh compile.
      command.writtenInterfaceSpec = (
        path: '${tmp.path}/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: report.path,
        extendable: true,
        specChange: InterfaceSpecChange.unknown
      );
      command.checkInterfaceReportAfterBuild();
      verify(
        () => logger.warn(
          any(
            that: contains('cannot tell whether the compile was reused'),
          ),
        ),
      ).called(1);

      report.writeAsStringSync('{}');
      command.checkInterfaceReportAfterBuild();
      expect(command.interfaceReportObservedAfterBuild, true);
      verifyNever(() => logger.warn(any()));
    });

    test('the attested spec reaches the archive service', () {
      final archive = MockArchiveService();
      when(
        () => archive.archiveIosRelease(
          releaseId: any(named: 'releaseId'),
          baselineId: any(named: 'baselineId'),
          fcpVersion: any(named: 'fcpVersion'),
          interfaceSpecPath: any(named: 'interfaceSpecPath'),
          interfaceReportPath: any(named: 'interfaceReportPath'),
          interfaceReportWasProduced: any(named: 'interfaceReportWasProduced'),
          interfaceSpecExtendable: any(named: 'interfaceSpecExtendable'),
          interfaceSpecChange: any(named: 'interfaceSpecChange'),
        ),
      ).thenReturn(true);
      final cmd = CodePushReleaseSubCommand(
        logger,
        buildService: buildService,
        archiveService: archive,
      );

      cmd.writtenInterfaceSpec = (
        path: '/x/dynamic_interface.yaml',
        reportPath: '/x/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.unchanged
      );
      cmd.interfaceReportObservedAfterBuild = true;
      cmd.archiveIosBaseline(releaseId: 'rel-1', baselineId: 'base-1');
      verify(
        () => archive.archiveIosRelease(
          releaseId: 'rel-1',
          baselineId: 'base-1',
          fcpVersion: any(named: 'fcpVersion'),
          interfaceSpecPath: '/x/dynamic_interface.yaml',
          interfaceReportPath: '/x/dynamic_interface_report.json',
          interfaceReportWasProduced: true,
          interfaceSpecExtendable: true,
          interfaceSpecChange: InterfaceSpecChange.unchanged,
        ),
      ).called(1);

      cmd.writtenInterfaceSpec = null;
      cmd.interfaceReportObservedAfterBuild = false;
      cmd.archiveIosBaseline(releaseId: 'rel-2', baselineId: 'base-2');
      verify(
        () => archive.archiveIosRelease(
          releaseId: 'rel-2',
          baselineId: 'base-2',
          fcpVersion: any(named: 'fcpVersion'),
          interfaceSpecPath: null,
          interfaceReportPath: null,
          interfaceReportWasProduced: false,
          interfaceSpecExtendable: false,
          interfaceSpecChange: null,
        ),
      ).called(1);
    });

    test("a previous run's report is deleted before the build", () async {
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
          flutterCount: 2,
          extendable: true,
          specChange: InterfaceSpecChange.unchanged
        ),
      );
      // fcp never writes the report; only the build does. A leftover
      // must not survive to be archived as this run's evidence.
      final staleReport = File(
        '${tmp.path}/build/codepush/dynamic_interface_report.json',
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('{"stale": true}');
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(freeze, isNotNull);
      expect(staleReport.existsSync(), false);
    });

    test('build-failure hint names the escape hatch for the freeze', () {
      expect(command.buildFailureFreezeHint(), isNull);

      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.unchanged
      );
      expect(
        command.buildFailureFreezeHint(),
        allOf(
          contains('--no-extendable-widgets'),
          contains('--no-interface-freeze'),
        ),
      );

      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: false,
        specChange: InterfaceSpecChange.unchanged
      );
      expect(
        command.buildFailureFreezeHint(),
        allOf(
          isNot(contains('--no-extendable-widgets')),
          contains('--no-interface-freeze'),
        ),
      );
    });

    test('failReleaseStep surfaces diagnostics and the freeze hint', () {
      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.unchanged
      );
      command.failReleaseStep(progress, 'Build failed', diagnostics: 'boom');
      verify(() => progress.fail('Build failed')).called(1);
      verify(() => logger.err('boom')).called(1);
      verify(
        () => logger.err(any(that: contains('--no-extendable-widgets'))),
      ).called(1);

      // No freeze applied: fail the line, add nothing misleading.
      command.writtenInterfaceSpec = null;
      command.failReleaseStep(progress, 'Finalization failed');
      verify(() => progress.fail('Finalization failed')).called(1);
      verifyNever(
        () => logger.err(any(that: contains('interface freeze'))),
      );
    });

    test('comma in the project path fails fast, before any compile', () async {
      final commaDir = Directory('${tmp.path}/a,b')..createSync();
      File('${commaDir.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      final freeze = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: commaDir.path,
      );
      expect(freeze, isNull);
      verify(() => logger.err(any(that: contains('comma-free')))).called(1);
      verifyNever(
        () => buildService.discoverCompileClosure(
          targetPath: any(named: 'targetPath'),
          workDirPath: any(named: 'workDirPath'),
        ),
      );
    });

    test('unsupported front-end fails before any compile', () async {
      when(() => buildService.frontendSupportsFreeze(any())).thenReturn(false);
      // The refusal must not leave a previous run's spec next to the
      // report this run already deleted.
      final stale = File(
        '${tmp.path}/build/codepush/dynamic_interface_01dc0ffedeadbeef.yaml',
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('old\n');
      final result = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(result, isNull);
      expect(stale.existsSync(), false);
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

    test('failed closure discovery also sweeps the previous spec', () async {
      when(
        () => buildService.discoverCompileClosure(
          targetPath: any(named: 'targetPath'),
          workDirPath: any(named: 'workDirPath'),
          projectRootOverride: any(named: 'projectRootOverride'),
        ),
      ).thenAnswer((_) async => null);
      final stale = File(
        '${tmp.path}/build/codepush/dynamic_interface_01dc0ffedeadbeef.yaml',
      )
        ..createSync(recursive: true)
        ..writeAsStringSync('old\n');
      final result = await command.prepareIosInterfaceFreeze(
        buildService,
        projectRootOverride: tmp.path,
      );
      expect(result, isNull);
      expect(stale.existsSync(), false);
      verify(
        () => progress.fail('Could not analyze the app for the release build'),
      ).called(1);
    });

    test(
        'interfaceAttestation: only an un-overridden iOS build this '
        'run attests', () {
      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.unchanged
      );
      command.interfaceReportObservedAfterBuild = true;

      // The one direction the feature must never fail in: an explicit
      // --snapshot uploads bytes the build did not produce — foreign
      // bytes must attest NOTHING, never true.
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: true,
        ),
        (interfaceFreeze: null, extendableWidgets: null),
      );
      expect(
        command.interfaceAttestation(
          shouldBuild: false,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: null, extendableWidgets: null),
      );
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'apk',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: null, extendableWidgets: null),
      );
      // The honest build attests the record's truth.
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: true, extendableWidgets: true),
      );
    });

    test(
        'interfaceAttestation: freeze off is a fact; contradicted '
        'evidence is unknown', () {
      // --no-interface-freeze: intent and fact agree — false, false.
      command.writtenInterfaceSpec = null;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: false, extendableWidgets: false),
      );

      // Changed spec + no compiler report = the suspected-SDK-drift
      // state: the server record must not out-claim the archive.
      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.changed
      );
      command.interfaceReportObservedAfterBuild = false;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: null, extendableWidgets: null),
      );

      // The same changed spec WITH its report is evidence — attest.
      command.interfaceReportObservedAfterBuild = true;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: true, extendableWidgets: true),
      );
    });

    test(
        'interfaceAttestation: --no-extendable-widgets is the row the '
        'warning exists for — freeze true, guarding FALSE', () {
      // The only attestation whose two bits differ, and the bit the
      // feature is named after: hard-coding extendableWidgets: true
      // (or wiring the wrong field) would pass every other test
      // while making every unguarded release read as guarded on the
      // server — silent, and only observable as a device crash.
      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: false,
        specChange: InterfaceSpecChange.unchanged
      );
      command.interfaceReportObservedAfterBuild = true;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: true, extendableWidgets: false),
      );
    });

    test(
        'interfaceAttestation: a from-scratch build (unknown spec '
        'state) with no report is unknown, not attested', () {
      // The clean-CI case: no previous spec swept, so specChange is
      // unknown and the compile ran from scratch — a cache hit cannot
      // explain a missing report. Attesting true here would silence
      // the patch-time warning on the ordinary way a release is cut.
      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.unknown
      );
      command.interfaceReportObservedAfterBuild = false;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: null, extendableWidgets: null),
      );

      // With the report observed, unknown spec state is fine — the
      // report itself is the evidence.
      command.interfaceReportObservedAfterBuild = true;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: true, extendableWidgets: true),
      );

      // Only an unchanged spec excuses a missing report (the cache
      // hit reused a compile of these exact bytes).
      command.writtenInterfaceSpec = (
        path: '/spec/dynamic_interface_abcd1234abcd1234.yaml',
        reportPath: '/spec/dynamic_interface_report.json',
        extendable: true,
        specChange: InterfaceSpecChange.unchanged
      );
      command.interfaceReportObservedAfterBuild = false;
      expect(
        command.interfaceAttestation(
          shouldBuild: true,
          builtPlatform: 'ios',
          usedExplicitSnapshot: false,
        ),
        (interfaceFreeze: true, extendableWidgets: true),
      );
    });
  });

  group('blankArgError', () {
    test(
        'present-but-blank --snapshot/--version/--app-id reject; '
        'absent keeps the fallback', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());

      // --snapshot blank is the worst: it fell through to
      // auto-discovery and recorded whatever the local build tree
      // held as THIS version's baseline identity.
      cmd.parsedArgs = cmd.argParser.parse(['--snapshot', '']);
      expect(cmd.blankArgError(), contains('Empty --snapshot'));

      cmd.parsedArgs = cmd.argParser.parse(['--version', '  ']);
      expect(cmd.blankArgError(), contains('Empty --version'));

      cmd.parsedArgs = cmd.argParser.parse(['--app-id', '']);
      expect(cmd.blankArgError(), contains('Empty --app-id'));

      // One row per list entry: blankArgError is a loop over a
      // string list, so deleting an entry is a silent, fully green
      // regression without these.
      cmd.parsedArgs = cmd.argParser.parse(['--flutter-version', ' ']);
      expect(cmd.blankArgError(), contains('Empty --flutter-version'));
      cmd.parsedArgs = cmd.argParser.parse(['--baseline-id', '']);
      expect(cmd.blankArgError(), contains('Empty --baseline-id'));

      // Absent flags keep their fallbacks (build / pubspec / stored
      // config) — only present-but-blank rejects.
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.blankArgError(), isNull);
      cmd.parsedArgs = cmd.argParser.parse(
        ['--snapshot', 'build/app.so', '--version', '1.0.0+1'],
      );
      expect(cmd.blankArgError(), isNull);
    });
  });

  group('version resolution', () {
    test(
        'pubspecVersionValue: comments and quotes are the parser\'s '
        'problem', () {
      // Both shapes are ordinary, legal pubspec that the end-of-line
      // capture keeps.
      expect(
        CodePushReleaseSubCommand.pubspecVersionValue('1.0.0+1 # bumped'),
        '1.0.0+1',
      );
      expect(
        CodePushReleaseSubCommand.pubspecVersionValue('"1.0.0+1"'),
        '1.0.0+1',
      );
      expect(
        CodePushReleaseSubCommand.pubspecVersionValue("'1.0.0'"),
        '1.0.0',
      );
      expect(
        CodePushReleaseSubCommand.pubspecVersionValue('"1.0.0+1" # x'),
        '1.0.0+1',
      );
      expect(
        CodePushReleaseSubCommand.pubspecVersionValue('1.0.0+1'),
        '1.0.0+1',
      );
    });

    test('versionValidationError: shared predicate, producer named', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      expect(
        cmd.versionValidationError('1.0.0+1', source: '--version'),
        isNull,
      );
      // The mid-build ArgumentError class: whitespace and parens can
      // be neither stamped nor matched — exit 64 naming the producer.
      expect(
        cmd.versionValidationError('1.0.0 (42)', source: 'pubspec.yaml'),
        allOf(contains('1.0.0 (42)'), contains('pubspec.yaml')),
      );
      expect(
        cmd.versionValidationError('a b', source: '--version'),
        contains('--version'),
      );
    });
  });
}
