@TestOn('!windows')
library;

import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

class _MockArtifactManager extends Mock implements CodePushArtifactManager {}

void main() {
  late Directory tmp;
  late _MockLogger logger;
  late CodePushBuildService service;
  late _MockArtifactManager artifacts;

  /// Writes an executable stub build tool running [script] (`/bin/sh`
  /// body; `"$@"` are the subcommand args). Returns its path.
  String stubTool(String script) {
    final f = File('${tmp.path}/build-tool-stub')
      ..writeAsStringSync('#!/bin/sh\n$script\n');
    Process.runSync('chmod', ['+x', f.path]);
    return f.path;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('prepare_cli_');
    logger = _MockLogger();
    service = CodePushBuildService(logger: logger);
    artifacts = _MockArtifactManager();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  // Android on purpose: the iOS arm installs SDK overlays first, which
  // is a different failure surface. This exercises the tool step alone.
  Future<bool> run() => service.prepareCodePushBuild(
        buildPlatform: 'apk',
        artifactManager: artifacts,
      );

  group('prepareCodePushBuild failure reporting', () {
    test(
        "echoes the tool's stderr — the reason the setup hint cannot "
        'give', () async {
      // The reported case: the real cause was something "fcp codepush
      // setup" cannot fix, and the only line on screen told the
      // operator to run it. The stderr must reach them.
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async => stubTool(
          "echo 'error: SDK version mismatch (expected 3.41.2, "
          "found 3.29.3)' >&2; exit 1",
        ),
      );

      expect(await run(), isFalse);
      verify(
        () => logger.err(any(that: contains('SDK version mismatch'))),
      ).called(1);
    });

    test('falls back to stdout when the tool reported its failure there',
        () async {
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async => stubTool("echo 'error: no such target'; exit 2"),
      );

      expect(await run(), isFalse);
      verify(
        () => logger.err(any(that: contains('no such target'))),
      ).called(1);
    });

    test('a silent failure still names the exit code', () async {
      when(() => artifacts.ensureBuildTool())
          .thenAnswer((_) async => stubTool('exit 3'));

      expect(await run(), isFalse);
      verify(
        () => logger.err(any(that: contains('exit code 3'))),
      ).called(1);
    });

    test('a present-but-unusable tool binary fails cleanly, not a crash',
        () async {
      // No execute bit → Process.runSync throws ProcessException.
      final f = File('${tmp.path}/build-tool-stub')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      when(() => artifacts.ensureBuildTool()).thenAnswer((_) async => f.path);

      expect(await run(), isFalse);
      verify(
        () => logger.err(any(that: contains('setup --force'))),
      ).called(1);
    });

    test('a successful prepare reports nothing', () async {
      when(() => artifacts.ensureBuildTool())
          .thenAnswer((_) async => stubTool('exit 0'));

      expect(await run(), isTrue);
      verifyNever(() => logger.err(any()));
    });

    test('a missing tool keeps its own actionable message', () async {
      when(() => artifacts.ensureBuildTool()).thenAnswer((_) async => null);

      expect(await run(), isFalse);
      verify(
        () => logger.err(any(that: contains('fcp codepush setup'))),
      ).called(1);
    });
  });

  group('failureOutputOf', () {
    test('prefers stderr, falls back to stdout, trims, and can be empty', () {
      expect(
        CodePushBuildService.failureOutputOf(
          ProcessResult(0, 1, 'out\n', '  boom \n'),
        ),
        'boom',
      );
      expect(
        CodePushBuildService.failureOutputOf(ProcessResult(0, 1, 'out\n', '')),
        'out',
      );
      expect(
        CodePushBuildService.failureOutputOf(
          ProcessResult(0, 1, '  \n', '  \n'),
        ),
        isEmpty,
      );
    });

    test('non-String stdio (a bytes-encoding run) degrades to empty', () {
      // stdoutEncoding: null yields List<int>; reading it `as String`
      // would throw inside a failure path, turning a reportable error
      // into a crash.
      expect(
        CodePushBuildService.failureOutputOf(
          ProcessResult(0, 1, <int>[1, 2, 3], <int>[4, 5]),
        ),
        isEmpty,
      );
    });
  });
}
