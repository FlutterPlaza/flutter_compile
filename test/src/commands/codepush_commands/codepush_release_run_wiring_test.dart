@TestOn('!windows')
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_release.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../../helpers/temp_home.dart';

class _MockLogger extends Mock implements Logger {}

class _MockProgress extends Mock implements Progress {}

class _MockBuildService extends Mock implements CodePushBuildService {}

class _FakeArtifactManager extends Fake implements CodePushArtifactManager {}

/// Exposes the command with parsed args so [CodePushReleaseSubCommand.run]
/// itself can be exercised — the call sites this file pins live inside
/// `run()`, and a direct call would see a null `argResults`.
class _ParsedArgsReleaseCommand extends CodePushReleaseSubCommand {
  _ParsedArgsReleaseCommand(super.logger, {super.buildService});

  ArgResults? parsedArgs;

  @override
  ArgResults? get argResults => parsedArgs;
}

void main() {
  final tempHome = TempHome();
  late Directory project;
  late Directory previousCwd;
  late _MockLogger logger;
  late _MockBuildService buildService;
  late List<String>? capturedBuildArgs;
  late String? capturedBuildPlatform;

  setUpAll(() {
    registerFallbackValue(_FakeArtifactManager());
  });

  setUp(() async {
    tempHome.setUp();
    await CodePushClient.storeToken('test-token');

    // A throwaway project: `run()` reaches for ios/Runner/Info.plist and
    // the Android config asset relative to the current directory, and
    // must not touch this repo's own tree. Both are absent here, which
    // is a supported (warned, unstamped) state and stops well short of
    // the build call this file is about.
    previousCwd = Directory.current;
    project = Directory.systemTemp.createTempSync('release_run_');
    File('${project.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
    Directory.current = project;
    addTearDown(() {
      Directory.current = previousCwd;
      project.deleteSync(recursive: true);
      tempHome.tearDown();
    });

    logger = _MockLogger();
    final progress = _MockProgress();
    when(() => logger.progress(any())).thenReturn(progress);
    when(() => logger.detail(any())).thenReturn(null);
    when(() => logger.info(any())).thenReturn(null);
    when(() => logger.err(any())).thenReturn(null);
    when(() => logger.warn(any())).thenReturn(null);
    when(() => progress.fail(any())).thenReturn(null);
    when(() => progress.complete(any())).thenReturn(null);

    capturedBuildArgs = null;
    capturedBuildPlatform = null;
    buildService = _MockBuildService();
    when(() => buildService.detectPlatform()).thenReturn(null);
    when(
      () => buildService.resolveFlutterVersion(
        explicit: any(named: 'explicit'),
        buildPlatform: any(named: 'buildPlatform'),
        artifactManager: any(named: 'artifactManager'),
      ),
    ).thenAnswer((_) async => '3.41.2');
    when(
      () => buildService.prepareCodePushBuild(
        buildPlatform: any(named: 'buildPlatform'),
        flutterVersion: any(named: 'flutterVersion'),
        artifactManager: any(named: 'artifactManager'),
      ),
    ).thenAnswer((_) async => true);
    // Returning false ends `run()` right after the call: everything this
    // file asserts has already happened, and nothing downstream (an
    // upload, a real server) is reached.
    when(
      () => buildService.buildRelease(
        platform: any(named: 'platform'),
        target: any(named: 'target'),
        extraArgs: any(named: 'extraArgs'),
        artifactManager: any(named: 'artifactManager'),
        flutterVersion: any(named: 'flutterVersion'),
      ),
    ).thenAnswer((invocation) async {
      capturedBuildPlatform = invocation.namedArguments[#platform] as String?;
      capturedBuildArgs =
          invocation.namedArguments[#extraArgs] as List<String>?;
      return false;
    });
  });

  Future<int> runRelease(List<String> args) {
    final command = _ParsedArgsReleaseCommand(
      logger,
      buildService: buildService,
    );
    command.parsedArgs = command.argParser.parse(args);
    return command.run();
  }

  const baseArgs = [
    '--build',
    '--app-id',
    'app-1',
    '--version',
    '1.0.0+1',
    '--dart-define',
    'FOO=bar',
  ];

  group('buildRelease call site', () {
    test(
        'an iOS release build gets the iOS-only gen-snapshot options '
        'merged into the dart-defines it was given', () async {
      // The wire the DI harness exists for: nothing else observes this
      // call site, so dropping the augmentation would ship an iOS
      // baseline built without its release options, suite green.
      await runRelease([
        ...baseArgs,
        '--platform',
        'ios',
        '--no-interface-freeze',
      ]);

      expect(capturedBuildPlatform, 'ios');
      expect(
        capturedBuildArgs,
        CodePushBuildService.withIosReleaseGenSnapshotOptions(
          const ['--dart-define=FOO=bar'],
        ),
      );
      // Not merely "contains": the augmentation must WRAP the caller's
      // args, not replace them.
      expect(capturedBuildArgs, contains('--dart-define=FOO=bar'));
      expect(capturedBuildArgs, hasLength(2));
    });

    test('every other platform gets the args unaugmented', () async {
      for (final platform in ['apk', 'appbundle', 'macos', 'linux']) {
        capturedBuildArgs = null;
        await runRelease([...baseArgs, '--platform', platform]);

        expect(capturedBuildPlatform, platform, reason: platform);
        expect(
          capturedBuildArgs,
          const ['--dart-define=FOO=bar'],
          reason: platform,
        );
      }
    });
  });

  group('--no-interface-freeze warning', () {
    test(
        'names the guarding flag it silently disables — the one flag '
        'combination whose effect is invisible until a device runs a '
        'patch that adds a widget', () async {
      await runRelease([
        ...baseArgs,
        '--platform',
        'ios',
        '--no-interface-freeze',
      ]);

      verify(() => logger.warn(kInterfaceFreezeDisabledWarning)).called(1);
      expect(
        kInterfaceFreezeDisabledWarning,
        contains('--no-interface-freeze'),
      );
      expect(
        kInterfaceFreezeDisabledWarning,
        contains('--extendable-widgets'),
      );
    });

    test('is not emitted for a non-iOS build, where the flag does not apply',
        () async {
      await runRelease([...baseArgs, '--platform', 'apk']);

      verifyNever(() => logger.warn(kInterfaceFreezeDisabledWarning));
    });
  });
}
