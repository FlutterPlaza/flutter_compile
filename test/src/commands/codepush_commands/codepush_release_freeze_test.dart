import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_release.dart';
import 'package:flutter_compile/src/shared/codepush_archive_service.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/interface_freeze_constants.dart';
import 'package:flutter_compile/src/shared/ios_baseline_plist.dart'
    show kDefaultBuiltIosAppPath;
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
      cmd.parsedArgs = cmd.argParser.parse(['--app-id', '  ']);
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
      // A '#' NOT preceded by whitespace is part of the scalar in
      // YAML — it must survive to the validator's rejection, never
      // be truncated into a version the pubspec does not contain.
      expect(
        CodePushReleaseSubCommand.pubspecVersionValue('1.0.0#1'),
        '1.0.0#1',
      );
    });

    test('pubspecVersionFrom: one line only; valueless falls through', () {
      // \s would cross the newline and read 'environment:' as the
      // version — a hard exit naming a line the operator never wrote.
      expect(
        CodePushReleaseSubCommand.pubspecVersionFrom(
          'name: demo\nversion:\nenvironment:\n  sdk: ^3.4.0\n',
        ),
        isNull,
      );
      expect(
        CodePushReleaseSubCommand.pubspecVersionFrom(
          'name: demo\nversion: "1.0.0+1" # bumped\n',
        ),
        '1.0.0+1',
      );
      expect(
        CodePushReleaseSubCommand.pubspecVersionFrom('name: demo\n'),
        isNull,
      );
    });

    test('usedExplicitSnapshot: foreign bytes, not the flag', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      // Shared by the attestation, the baseline-app save, and the
      // archive gate — the three records agree because this is ONE
      // read. The question is byte provenance: the built binary's
      // OWN path passed explicitly (the spelling the guidance
      // teaches) is still the frozen build.
      cmd.parsedArgs = cmd.argParser.parse(['--snapshot', 'app.bin']);
      expect(cmd.usedExplicitSnapshot, isTrue);
      cmd.parsedArgs = cmd.argParser.parse([
        '--snapshot',
        'build/ios/iphoneos/Runner.app/Frameworks/App.framework/App',
      ]);
      expect(cmd.usedExplicitSnapshot, isFalse);
      cmd.parsedArgs = cmd.argParser.parse(
        ['--snapshot', '/elsewhere/Other.app/Frameworks/App.framework/App'],
      );
      expect(cmd.usedExplicitSnapshot, isTrue);
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.usedExplicitSnapshot, isFalse);
      // Blank AND whitespace read as absent (trimmed like every
      // boundary read); blankArgError rejects both earlier in run().
      cmd.parsedArgs = cmd.argParser.parse(['--snapshot', '']);
      expect(cmd.usedExplicitSnapshot, isFalse);
      cmd.parsedArgs = cmd.argParser.parse(['--snapshot', '  ']);
      expect(cmd.usedExplicitSnapshot, isFalse);
    });

    test('buildOnlyFlagsWarning (release): ignored flags warn', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      cmd.parsedArgs = cmd.argParser.parse(
        ['--no-extendable-widgets', '--snapshot', 'app.bin'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(),
        contains('--[no-]extendable-widgets'),
      );
      cmd.parsedArgs = cmd.argParser.parse(['--dart-define', 'A=1']);
      expect(cmd.buildOnlyFlagsWarning(), contains('--dart-define'));
      // The interface-freeze clause needs its own row, and wasParsed
      // (not the value) is the predicate: explicitly passing the
      // DEFAULT ('--extendable-widgets', value true) must still warn
      // — a value-based read would silently drop it.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--interface-freeze', '--snapshot', 'app.bin'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(),
        contains('--[no-]interface-freeze'),
      );
      cmd.parsedArgs = cmd.argParser.parse(['--extendable-widgets']);
      expect(
        cmd.buildOnlyFlagsWarning(),
        contains('--[no-]extendable-widgets'),
      );
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--no-extendable-widgets'],
      );
      expect(cmd.buildOnlyFlagsWarning(), isNull);
      // Grammar pinned (issue #67 L4), same sentence as the patch
      // twin: singular 'is', plural 'are'.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--baseline-id', 'b-1'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'apk'),
        endsWith('is iOS-only; ignoring on apk builds.'),
      );
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--baseline-id', 'b-1', '--allow-missing-baseline'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'apk'),
        endsWith('are iOS-only; ignoring on apk builds.'),
      );
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(cmd.buildOnlyFlagsWarning(), isNull);
    });

    test(
        'usedExplicitSnapshot: the PHYSICAL tier decides through '
        'symlinked prefixes', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      // systemTemp itself is the symlinked prefix on macOS
      // (/var -> /private/var): the logical and physical spellings
      // of the same app dir differ there, and only the physical
      // tier equates them — deleting it (keeping the lexical
      // fallback) turns this row red on macOS. On Linux the two
      // spellings coincide and the row still passes.
      final root = Directory.systemTemp.createTempSync('fcp_phys');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/$kDefaultBuiltIosAppPath')
          .createSync(recursive: true);
      final physicalAppDir = Directory('${root.path}/$kDefaultBuiltIosAppPath')
          .resolveSymbolicLinksSync();
      cmd.parsedArgs = cmd.argParser.parse(
        ['--snapshot', '$physicalAppDir/Frameworks/App.framework/App'],
      );
      expect(
        cmd.snapshotIsForeignTo(projectRootOverride: root.path),
        isFalse,
      );
      // A SYMLINK spelling makes the two paths differ on EVERY
      // POSIX platform (the systemTemp prefix only differs on
      // macOS), so deleting the physical tier goes red on Linux CI
      // too. Gated off on Windows: symlink creation there needs
      // Developer Mode or an elevated token — an undeclared runner-
      // image dependency for a row whose subject is POSIX-only.
      if (!Platform.isWindows) {
        Link('${root.path}/via_link').createSync(root.path);
        cmd.parsedArgs = cmd.argParser.parse([
          '--snapshot',
          '${root.path}/via_link/$kDefaultBuiltIosAppPath'
              '/Frameworks/App.framework/App',
        ]);
        expect(
          cmd.snapshotIsForeignTo(projectRootOverride: root.path),
          isFalse,
        );
      }
      // A genuinely different app dir under the same root stays
      // foreign through the same tier.
      Directory('${root.path}/Other.app').createSync(recursive: true);
      cmd.parsedArgs = cmd.argParser.parse(
        ['--snapshot', '${root.path}/Other.app/Frameworks/App.framework/App'],
      );
      expect(
        cmd.snapshotIsForeignTo(projectRootOverride: root.path),
        isTrue,
      );
    });

    test('identity flags on a non-iOS NO-BUILD release warn', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      // The split made 'iOS' the load-bearing word: a no-build apk
      // release with --baseline-id is read by nothing and must say
      // so — while on ios it is genuinely read and stays silent.
      cmd.parsedArgs = cmd.argParser.parse(
        ['--baseline-id', 'u-1', '--snapshot', 'app.bin'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'apk'),
        contains('only used for iOS releases'),
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'ios'),
        isNull,
      );
    });

    test('the identity flags are NOT build-only: no false ignore', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      // The documented pre-built-app flow: --baseline-id (and its
      // escape hatch) are read on every iOS release, build or not —
      // warning that they are ignored is the inverse defect (read,
      // and says it isn't).
      cmd.parsedArgs = cmd.argParser.parse(
        ['--baseline-id', 'u-1', '--snapshot', 'app.bin'],
      );
      expect(cmd.buildOnlyFlagsWarning(), isNull);
      cmd.parsedArgs = cmd.argParser.parse(
        ['--allow-missing-baseline', '--snapshot', 'app.bin'],
      );
      expect(cmd.buildOnlyFlagsWarning(), isNull);
      // On the PLATFORM axis they still warn (an apk build reads
      // neither).
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--baseline-id', 'u-1'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'apk'),
        contains('--baseline-id'),
      );
    });

    test('buildOnlyFlagsWarning (release): the platform axis', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      cmd.parsedArgs = cmd.argParser.parse(
        ['--build', '--no-extendable-widgets'],
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'apk'),
        contains('--[no-]extendable-widgets'),
      );
      expect(
        cmd.buildOnlyFlagsWarning(resolvedPlatform: 'ios'),
        isNull,
      );
    });

    test('saveIosBaselineApp is best-effort by construction', () {
      final logger = MockLogger();
      when(() => logger.warn(any())).thenReturn(null);
      when(() => logger.detail(any())).thenReturn(null);
      final cmd = ParsedArgsReleaseCommand(logger);
      final root = Directory.systemTemp.createTempSync('fcp_save');
      addTearDown(() => root.deleteSync(recursive: true));
      // A built app exists, but the dest PARENT path is blocked by a
      // plain file — the mkdir throws, and the method must warn, not
      // throw (a post-success step must never fail the release).
      Directory('${root.path}/$kDefaultBuiltIosAppPath')
          .createSync(recursive: true);
      File('${root.path}/build/codepush')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync([1]);
      final saved = cmd.saveIosBaselineApp(
        baselineId: 'b-1',
        projectRootOverride: root.path,
      );
      verify(
        () => logger.warn(any(that: contains('Saved-baseline step skipped'))),
      ).called(1);
      // FALSE gates the archive at the caller: archiving whatever
      // (possibly the PREVIOUS release's bundle) sits at the saved
      // path under this release's id would break two-records-one-
      // story.
      expect(saved, isFalse);
    });

    group('snapshotArgError (--snapshot stat)', () {
      test(
          'a typo without --build is an argument error, not a late '
          'failure', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        cmd.parsedArgs =
            cmd.argParser.parse(['--snapshot', '/definitely/not/here.bin']);
        expect(
          cmd.snapshotArgError(willBuild: false),
          contains('Snapshot file not found'),
        );
        // With --build the missing-FILE case defers to the warning.
        expect(cmd.snapshotArgError(willBuild: true), isNull);
      });

      test('an existing file passes; no flag is silent', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snaparg');
        addTearDown(() => root.deleteSync(recursive: true));
        final f = File('${root.path}/app.bin')..writeAsBytesSync([1]);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', f.path]);
        expect(cmd.snapshotArgError(willBuild: false), isNull);
        expect(cmd.snapshotArgError(willBuild: true), isNull);
        final bare = ParsedArgsReleaseCommand(MockLogger());
        bare.parsedArgs = bare.argParser.parse([]);
        expect(bare.snapshotArgError(willBuild: false), isNull);
      });

      test(
          'a directory is a FACT: rejected up front with or without '
          '--build when outside build/', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapdir');
        addTearDown(() => root.deleteSync(recursive: true));
        final outside = Directory('${root.path}/exported/Runner.app')
          ..createSync(recursive: true);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', outside.path]);
        final noBuild = cmd.snapshotArgError(willBuild: false)!;
        expect(noBuild, contains('names a directory'));
        expect(noBuild, isNot(contains('not found')));
        // No build turns a directory outside build/ into a file:
        // burning the build first proves nothing (round-5 M3).
        expect(
          cmd.snapshotArgError(willBuild: true),
          contains('names a directory'),
        );
      });

      group('baselineIdContradiction (flag vs built bytes)', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        String? call({
          bool shouldBuild = true,
          bool foreign = false,
          String? stamped,
          String? flag = 'abc',
          String? embedded,
        }) =>
            cmd.baselineIdContradiction(
              shouldBuild: shouldBuild,
              snapshotIsForeign: foreign,
              stampedByThisBuild: stamped,
              explicitFlag: flag,
              embeddedInBuiltApp: embedded,
              stampFailureCause: 'cause-x',
            );

        test(
            'a MATCHING flag is accepted — the pre-stamped read-only '
            'checkout flow the CHANGELOG recommends', () {
          expect(call(embedded: 'abc'), isNull);
        });
        test(
            'a case-different flag is REFUSED — reverting == to a '
            'fold records an id no device presents', () {
          expect(call(embedded: 'ABC'), contains('contradicts'));
        });
        test('a flag nothing embeds is refused, naming the stamp cause', () {
          expect(call(), contains('did not embed'));
          expect(call(), contains('cause-x'));
        });
        test(
            'out of scope: foreign snapshot, stamped run, no build, '
            'no flag', () {
          expect(call(foreign: true), isNull);
          expect(call(stamped: 'abc', embedded: null), isNull);
          expect(call(shouldBuild: false), isNull);
          expect(call(flag: null), isNull);
          expect(call(flag: ''), isNull);
        });
        test('blank operands read as absent, both sides trimmed', () {
          // An empty embedded id must NOT read as a present-but-empty
          // contradiction (that path would record '' as a baseline_id).
          expect(call(embedded: '   ', flag: 'abc'), contains('did not embed'));
          // A padded flag matching a clean embedded id is NOT a
          // contradiction.
          expect(call(flag: '  abc  ', embedded: 'abc'), isNull);
        });
      });

      group('iosStampCauseFor (exception shape → operator cause)', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        test('non-UTF-8 read (no OSError + decode message) → binary plist', () {
          expect(
            cmd.iosStampCauseFor(
              const FileSystemException(
                "Failed to decode data using encoding 'utf-8'",
                'ios/Runner/Info.plist',
              ),
            ),
            contains('binary plist'),
          );
        });
        test('EACCES → the directory, not just the file', () {
          expect(
            cmd.iosStampCauseFor(
              const FileSystemException(
                'Cannot create file',
                '.Info.plist.1.tmp',
                OSError('Permission denied', 13),
              ),
            ),
            contains('writable ios/Runner/ directory'),
          );
        });
        test('ENOSPC → disk, NOT permissions', () {
          final msg = cmd.iosStampCauseFor(
            const FileSystemException(
              'Cannot write',
              '.Info.plist.1.tmp',
              OSError('No space left on device', 28),
            ),
          );
          expect(msg, contains('no space'));
          expect(msg, isNot(contains('permissions')));
        });
        test(
            'EDQUOT on both platforms → the disk/quota branch, not '
            'neutral', () {
          // 69 (macOS/BSD) and 122 (Linux) both mean over-quota.
          for (final code in [69, 122]) {
            final msg = cmd.iosStampCauseFor(
              FileSystemException(
                'Cannot write',
                '.Info.plist.1.tmp',
                OSError('Disc quota exceeded', code),
              ),
            );
            expect(msg, contains('quota'));
            expect(msg, isNot(contains('permissions')));
          }
        });
        test('unknown OSError → neutral read-or-write', () {
          final msg = cmd.iosStampCauseFor(
            const FileSystemException(
              'Cannot write',
              '.Info.plist.1.tmp',
              OSError('I/O error', 5),
            ),
          );
          expect(msg, contains('could not be read'));
          expect(msg, isNot(contains('permissions')));
        });
      });

      group('stampConsumedWarning (stamp vs built bytes)', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        test('agreement (build consumed the stamp) → null', () {
          expect(
            cmd.stampConsumedWarning(
              stampedByThisBuild: 'id-1',
              embeddedInBuiltApp: 'id-1',
            ),
            isNull,
          );
        });
        test('built app embeds nothing → warns about the wrong plist', () {
          expect(
            cmd.stampConsumedWarning(
              stampedByThisBuild: 'id-1',
              embeddedInBuiltApp: null,
            ),
            contains('embeds no FCPBaselineId'),
          );
        });
        test('built app embeds a DIFFERENT id → warns, names both', () {
          final msg = cmd.stampConsumedWarning(
            stampedByThisBuild: 'id-1',
            embeddedInBuiltApp: 'id-2',
          )!;
          expect(msg, contains('id-2'));
          expect(msg, contains('id-1'));
          expect(msg, contains('releasing under the embedded id'));
        });
        test('blank operands read as absent (trim both)', () {
          expect(
            cmd.stampConsumedWarning(
              stampedByThisBuild: '  ',
              embeddedInBuiltApp: 'x',
            ),
            isNull,
          );
          expect(
            cmd.stampConsumedWarning(
              stampedByThisBuild: 'id-1',
              embeddedInBuiltApp: '  id-1  ',
            ),
            isNull,
          );
        });
      });

      group('baselineIdUnderOptOut (which id the opt-out releases under)', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        test('embedded id wins when the bytes carry one', () {
          expect(cmd.baselineIdUnderOptOut(embeddedInBuiltApp: ' ABC '), 'ABC');
        });
        test('null/blank embedded → identity-less', () {
          expect(cmd.baselineIdUnderOptOut(embeddedInBuiltApp: null), isNull);
          expect(cmd.baselineIdUnderOptOut(embeddedInBuiltApp: '  '), isNull);
        });
      });

      test('a dangling symlink reads as a dead link, not as "not found"', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snaplink');
        addTearDown(() => root.deleteSync(recursive: true));
        final link = Link('${root.path}/app.bin')
          ..createSync('${root.path}/never-built.bin');
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', link.path]);
        final msg = cmd.snapshotArgError(willBuild: false)!;
        expect(msg, contains('symbolic link'));
        expect(msg, isNot(contains('not found:')));
      }, skip: Platform.isWindows ? 'POSIX symlink semantics' : false);

      test(
          'a stale directory UNDER build/ defers to the post-build '
          'stat when --build will run — and is still rejected '
          'without --build', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapdirb');
        addTearDown(() => root.deleteSync(recursive: true));
        final under = Directory('${root.path}/build/stale/Runner.app')
          ..createSync(recursive: true);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', under.path]);
        // The carve-out: the build MAY clean build/ and rebuild the
        // path as a file, so an up-front rejection here would be the
        // false-reject the heuristic must never cause. Deferral, not
        // approval — the post-build stat still fails the run if the
        // directory survives.
        expect(
          cmd.snapshotArgError(
            willBuild: true,
            projectRootOverride: root.path,
          ),
          isNull,
        );
        // Without --build nothing can replace it: directory fact,
        // rejected with the directory text either side of build/.
        expect(
          cmd.snapshotArgError(
            willBuild: false,
            projectRootOverride: root.path,
          ),
          contains('names a directory'),
        );
      });
    });

    group('snapshotPreBuildWarning (--build --snapshot)', () {
      test('a missing path OUTSIDE build/ warns — never rejects', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapwarn');
        addTearDown(() => root.deleteSync(recursive: true));
        cmd.parsedArgs =
            cmd.argParser.parse(['--snapshot', '${root.path}/nope.bin']);
        expect(
          cmd.snapshotPreBuildWarning(projectRootOverride: root.path),
          contains('will fail after the build'),
        );
      });

      test('a missing path UNDER build/ is silent — the build may create it',
          () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapwarn2');
        addTearDown(() => root.deleteSync(recursive: true));
        cmd.parsedArgs = cmd.argParser
            .parse(['--snapshot', '${root.path}/build/future/App']);
        expect(
          cmd.snapshotPreBuildWarning(projectRootOverride: root.path),
          isNull,
        );
      });

      test(
          'an existing directory UNDER build/ warns as a DIRECTORY — '
          'never as a file that does not exist', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapwarn5');
        addTearDown(() => root.deleteSync(recursive: true));
        final under = Directory('${root.path}/build/ios/Runner.app')
          ..createSync(recursive: true);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', under.path]);
        // (An outside-build/ directory never reaches production
        // emission — snapshotArgError rejects it up front as a fact.)
        final warn =
            cmd.snapshotPreBuildWarning(projectRootOverride: root.path)!;
        expect(warn, contains('names a directory'));
        expect(warn, isNot(contains('does not exist')));
      });

      test('the containment test is case-folded (NTFS, default APFS)', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapwarn3');
        addTearDown(() => root.deleteSync(recursive: true));
        cmd.parsedArgs = cmd.argParser
            .parse(['--snapshot', '${root.path}/Build/future/App']);
        expect(
          cmd.snapshotPreBuildWarning(projectRootOverride: root.path),
          isNull,
        );
      });

      test('an existing file is silent wherever it lives', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_snapwarn4');
        addTearDown(() => root.deleteSync(recursive: true));
        final f = File('${root.path}/app.bin')..writeAsBytesSync([1]);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', f.path]);
        expect(
          cmd.snapshotPreBuildWarning(projectRootOverride: root.path),
          isNull,
        );
      });
    });

    group('foreignSnapshotAdvisory (pre-build)', () {
      test('an existing directory suppresses the foreign advisory', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_advsupp');
        addTearDown(() => root.deleteSync(recursive: true));
        final dir = Directory('${root.path}/build/ios/Runner.app')
          ..createSync(recursive: true);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', dir.path]);
        // The bundle-instead-of-binary mistake must never draw a
        // "foreign bytes" story beside the correct directory warning.
        expect(
          cmd.foreignSnapshotAdvisory(projectRootOverride: root.path),
          isNull,
        );
      });

      test('no --snapshot: silent', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        cmd.parsedArgs = cmd.argParser.parse([]);
        expect(cmd.foreignSnapshotAdvisory(), isNull);
      });

      test(
          'missing foreign bytes OUTSIDE build/: base only — the '
          'pre-build warning already owns the fail risk', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        cmd.parsedArgs =
            cmd.argParser.parse(['--snapshot', '/elsewhere/app.bin']);
        final advisory = cmd.foreignSnapshotAdvisory()!;
        expect(advisory, contains('will be skipped'));
        expect(advisory.toLowerCase(), isNot(contains('fail')));
      });

      test(
          'missing foreign bytes UNDER build/ keep the conditional '
          'clause — no pre-build warning fires there', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_advisory4');
        addTearDown(() => root.deleteSync(recursive: true));
        cmd.parsedArgs = cmd.argParser
            .parse(['--snapshot', '${root.path}/build/other/app.bin']);
        final advisory =
            cmd.foreignSnapshotAdvisory(projectRootOverride: root.path)!;
        expect(advisory, contains('If those bytes carry no readable'));
        expect(advisory, isNot(contains('FAIL after the build')));
      });

      test(
          "with an override, this build's own output under that root "
          'is not foreign: silent', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_advisory5');
        addTearDown(() => root.deleteSync(recursive: true));
        cmd.parsedArgs = cmd.argParser.parse([
          '--snapshot',
          '${root.path}/$kDefaultBuiltIosAppPath'
              '/Frameworks/App.framework/App',
        ]);
        expect(
          cmd.foreignSnapshotAdvisory(projectRootOverride: root.path),
          isNull,
        );
      });

      test(
          'foreign bytes that EXIST with no readable identity: certain '
          'failure, said before the build', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_advisory');
        addTearDown(() => root.deleteSync(recursive: true));
        final f = File('${root.path}/app.bin')..writeAsBytesSync([1]);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', f.path]);
        final advisory = cmd.foreignSnapshotAdvisory()!;
        expect(advisory, contains('FAIL after the build'));
      });

      test(
          'an id-less bundle UNDER build/ stays conditional — this '
          'build may rewrite it, stamp included', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        final root = Directory.systemTemp.createTempSync('fcp_advisory2');
        addTearDown(() => root.deleteSync(recursive: true));
        final f = File('${root.path}/build/stale/app.bin')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([1]);
        cmd.parsedArgs = cmd.argParser.parse(['--snapshot', f.path]);
        final advisory =
            cmd.foreignSnapshotAdvisory(projectRootOverride: root.path)!;
        expect(advisory, contains('will fail after the build'));
        expect(advisory, isNot(contains('FAIL after the build')));
      });

      test('--baseline-id settles the identity: no fail clause', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        cmd.parsedArgs = cmd.argParser.parse(
          ['--snapshot', '/elsewhere/app.bin', '--baseline-id', 'u-1'],
        );
        final advisory = cmd.foreignSnapshotAdvisory()!;
        expect(advisory, contains('will be skipped'));
        expect(advisory, contains('comes from --baseline-id'));
        expect(advisory.toLowerCase(), isNot(contains('fail')));
      });

      test('--allow-missing-baseline: skips named, nothing demanded', () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        cmd.parsedArgs = cmd.argParser.parse(
          ['--snapshot', '/elsewhere/app.bin', '--allow-missing-baseline'],
        );
        final advisory = cmd.foreignSnapshotAdvisory()!;
        expect(advisory, contains('will be skipped'));
        expect(advisory.toLowerCase(), isNot(contains('baseline identity')));
      });

      test("this build's own output path is not foreign: silent", () {
        final cmd = ParsedArgsReleaseCommand(MockLogger());
        cmd.parsedArgs = cmd.argParser.parse(
          [
            '--snapshot',
            '$kDefaultBuiltIosAppPath/Frameworks/App.framework/App',
          ],
        );
        expect(cmd.foreignSnapshotAdvisory(), isNull);
      });
    });

    group('saveIosBaselineApp copy-then-swap', () {
      late Directory root;
      late String dest;
      late ParsedArgsReleaseCommand cmd;
      late MockLogger logger;

      setUp(() {
        logger = MockLogger();
        when(() => logger.warn(any())).thenReturn(null);
        when(() => logger.detail(any())).thenReturn(null);
        when(() => logger.info(any())).thenReturn(null);
        when(() => logger.success(any())).thenReturn(null);
        cmd = ParsedArgsReleaseCommand(logger);
        root = Directory.systemTemp.createTempSync('fcp_swap');
        dest = '${root.path}/build/codepush/baseline/Runner.app';
        Directory('${root.path}/$kDefaultBuiltIosAppPath')
            .createSync(recursive: true);
        File('${root.path}/$kDefaultBuiltIosAppPath/marker.txt')
            .writeAsStringSync('new');
      });

      tearDown(() => root.deleteSync(recursive: true));

      test('a pre-existing saved bundle is replaced by the fresh one', () {
        Directory(dest).createSync(recursive: true);
        File('$dest/marker.txt').writeAsStringSync('old');
        final saved = cmd.saveIosBaselineApp(
          baselineId: 'b-1',
          projectRootOverride: root.path,
        );
        expect(saved, isTrue);
        expect(File('$dest/marker.txt').readAsStringSync(), 'new');
        expect(Directory('$dest.tmp').existsSync(), isFalse);
      });

      test(
          'a failed copy leaves the previous bundle intact — the reason '
          'the swap exists', () {
        Directory(dest).createSync(recursive: true);
        File('$dest/marker.txt').writeAsStringSync('old');
        // Make a SOURCE file unreadable so cp fails mid-copy — the
        // realistic failure shape — before any delete. This row goes
        // red if anyone reverts the save to delete-first. (Assumes a
        // non-root test process, as on this repo's CI runners: root
        // reads through mode 000 and cp would succeed.)
        final locked = File('${root.path}/$kDefaultBuiltIosAppPath/locked.txt')
          ..writeAsStringSync('x');
        Process.runSync('chmod', ['000', locked.path]);
        addTearDown(() => Process.runSync('chmod', ['644', locked.path]));
        final saved = cmd.saveIosBaselineApp(
          baselineId: 'b-1',
          projectRootOverride: root.path,
        );
        expect(saved, isFalse);
        expect(File('$dest/marker.txt').readAsStringSync(), 'old');
        verify(
          () => logger.warn(any(that: contains('left in place'))),
        ).called(1);
      });

      test(
          'a plain file occupying the temp path is cleared and the '
          'save lands — it must not block every subsequent run', () {
        File('$dest.tmp')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([1]);
        final saved = cmd.saveIosBaselineApp(
          baselineId: 'b-1',
          projectRootOverride: root.path,
        );
        expect(saved, isTrue);
        expect(File('$dest/marker.txt').readAsStringSync(), 'new');
        expect(
          FileSystemEntity.typeSync('$dest.tmp', followLinks: false),
          FileSystemEntityType.notFound,
        );
      });

      test('a stale temp from a killed run is cleared and the save lands', () {
        Directory('$dest.tmp').createSync(recursive: true);
        File('$dest.tmp/stale.txt').writeAsStringSync('stale');
        final saved = cmd.saveIosBaselineApp(
          baselineId: 'b-1',
          projectRootOverride: root.path,
        );
        expect(saved, isTrue);
        expect(File('$dest/marker.txt').readAsStringSync(), 'new');
        expect(File('$dest/stale.txt').existsSync(), isFalse);
        expect(Directory('$dest.tmp').existsSync(), isFalse);
      });

      test(
          'a swap blocked by a plain file at dest discards the copy and '
          'reports, leaving the blocker as-is', () {
        File(dest)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([7]);
        final saved = cmd.saveIosBaselineApp(
          baselineId: 'b-1',
          projectRootOverride: root.path,
        );
        expect(saved, isFalse);
        expect(File(dest).existsSync(), isTrue);
        expect(Directory('$dest.tmp').existsSync(), isFalse);
        verify(
          () => logger.warn(
            any(
              that: allOf(
                contains('could not swap'),
                contains('left as-is'),
              ),
            ),
          ),
        ).called(1);
      });

      test(
          'a swap failure whose cleanup ALSO fails reports the copy as '
          'still on disk — never claims a discard that did not happen', () {
        // rename blocked by a plain file at dest (the proven ENOTDIR
        // trigger above); the tmp delete then fails because cp -R
        // preserved a mode-555 subdirectory from the SOURCE app —
        // deleting its contents needs write on that directory.
        // (Assumes a non-root test process; root writes through 555.)
        File(dest)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync([7]);
        final lockedDir =
            Directory('${root.path}/$kDefaultBuiltIosAppPath/locked')
              ..createSync(recursive: true);
        File('${lockedDir.path}/inner.txt').writeAsStringSync('x');
        Process.runSync('chmod', ['555', lockedDir.path]);
        // Registered AFTER the root-delete tearDown, so it runs FIRST
        // (LIFO): both the source's and the stranded tmp copy's 555
        // dirs must be writable again or the root sweep itself fails.
        addTearDown(() {
          Process.runSync('chmod', ['755', lockedDir.path]);
          Process.runSync('chmod', ['-R', 'u+w', root.path]);
        });
        final saved = cmd.saveIosBaselineApp(
          baselineId: 'b-1',
          projectRootOverride: root.path,
        );
        expect(saved, isFalse);
        verify(
          () => logger.warn(
            any(
              that: allOf(
                contains('could not swap'),
                contains('could NOT be discarded'),
              ),
            ),
          ),
        ).called(1);
        // The report told the truth: the copy really is still there.
        expect(Directory('$dest.tmp').existsSync(), isTrue);
      });
    },
        skip:
            Platform.isWindows ? 'exercises POSIX cp/rename semantics' : false);

    test('dartDefineValues (release): filter applied at this command', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      cmd.parsedArgs = cmd.argParser.parse(
        ['--dart-define', 'BANNER=beta ', '--dart-define', '  '],
      );
      expect(cmd.dartDefineValues(), ['BANNER=beta ']);
    });

    test('platformArgOrError twin: forBuild wired, call pinned', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      // Flipping forBuild to false re-opens `release --build
      // --platform android` (a full engine preparation ending in
      // flutter's own usage error); the shared helper is tested via
      // the patch command, so THIS wire needs its own rows.
      cmd.parsedArgs = cmd.argParser.parse(['--build', '-p', 'android']);
      final (androidValue, androidError) = cmd.platformArgOrError();
      expect(androidValue, isNull);
      expect(androidError, contains('not a buildable target'));
      cmd.parsedArgs = cmd.argParser.parse(['-p', 'iOS']);
      expect(cmd.platformArgOrError(), ('ios', null));
    });

    test('pubspecContentForVersion: lazy and guarded', () {
      final logger = MockLogger();
      when(() => logger.detail(any())).thenReturn(null);
      final cmd = ParsedArgsReleaseCommand(logger);
      final root = Directory.systemTemp.createTempSync('fcp_pubspec');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/pubspec.yaml').writeAsStringSync('version: 1.0.0+1\n');

      // LAZY: a run that passed --version never reads the file, even
      // when a perfectly readable one exists.
      cmd.parsedArgs = cmd.argParser.parse(['--version', '2.0.0']);
      expect(
        cmd.pubspecContentForVersion(projectRootOverride: root.path),
        isNull,
      );

      // No flag: the content is returned; a missing file is null.
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(
        cmd.pubspecContentForVersion(projectRootOverride: root.path),
        contains('1.0.0+1'),
      );
      final empty = Directory.systemTemp.createTempSync('fcp_nopub');
      addTearDown(() => empty.deleteSync(recursive: true));
      expect(
        cmd.pubspecContentForVersion(projectRootOverride: empty.path),
        isNull,
      );

      // GUARDED: an unreadable pubspec degrades to null with the
      // cause at detail visibility, never an unhandled exception.
      // Mode bits are ignored for uid 0, so the row is also gated
      // off under root (root Docker CI) — brittle red, not green.
      final isRoot = !Platform.isWindows &&
          Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
      if (!Platform.isWindows && !isRoot) {
        final locked = Directory.systemTemp.createTempSync('fcp_locked');
        addTearDown(() {
          Process.runSync('chmod', ['644', '${locked.path}/pubspec.yaml']);
          locked.deleteSync(recursive: true);
        });
        File('${locked.path}/pubspec.yaml')
            .writeAsStringSync('version: 1.0.0+1\n');
        Process.runSync('chmod', ['000', '${locked.path}/pubspec.yaml']);
        expect(
          cmd.pubspecContentForVersion(projectRootOverride: locked.path),
          isNull,
        );
        verify(
          () => logger.detail(any(that: contains('Could not read'))),
        ).called(1);
      }
    });

    test('resolvedVersionAndSource: the SOURCE is pinned per branch', () {
      final cmd = ParsedArgsReleaseCommand(MockLogger());
      // Swapping the two assignments used to compile and pass green
      // while sending the operator to the wrong file.
      cmd.parsedArgs = cmd.argParser.parse(['--version', ' 2.0.0+5 ']);
      expect(
        cmd.resolvedVersionAndSource('version: 1.0.0+1\n'),
        ('2.0.0+5', '--version'),
      );
      cmd.parsedArgs = cmd.argParser.parse([]);
      expect(
        cmd.resolvedVersionAndSource('version: 1.0.0+1\n'),
        ('1.0.0+1', 'pubspec.yaml'),
      );
      expect(cmd.resolvedVersionAndSource(null), (null, 'pubspec.yaml'));
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
