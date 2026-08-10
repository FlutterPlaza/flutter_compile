@TestOn('!windows')
library;

import 'dart:convert';
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

  /// Writes an executable stub `fcp-tool` running [script] (`/bin/sh`
  /// body; `"$@"` are the subcommand args). Returns its path.
  String stubTool(String script) {
    final f = File('${tmp.path}/fcp-tool-stub')
      ..writeAsStringSync('#!/bin/sh\n$script\n');
    Process.runSync('chmod', ['+x', f.path]);
    return f.path;
  }

  /// A stub that scans its args for `--output` and writes [json] there.
  String stubToolWritingJson(String json) => stubTool('''
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--output" ]; then out="\$2"; fi
  shift
done
cat > "\$out" <<'EOF'
$json
EOF
''');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('engine_prep_cli_');
    logger = _MockLogger();
    service = CodePushBuildService(logger: logger);
    artifacts = _MockArtifactManager();
    when(() => artifacts.ensureAndroidEngine(
          flutterVersion: any(named: 'flutterVersion'),
        )).thenAnswer((_) async => true);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AndroidEnginePrep?> run() => service.prepareAndroidEngineBuild(
        flutterVersion: '3.41.6',
        artifactManager: artifacts,
        flutterRootOverride: tmp.path,
      );

  group('prepareAndroidEngineBuild', () {
    test('returns env and checksum from a well-formed tool result', () async {
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async => stubToolWritingJson(jsonEncode({
          'env': {'SOME_VAR': '/some/where'},
          'engine_sha256': 'abc123',
          'maven_version': '1.0.0-x',
        })),
      );

      final prep = await run();

      expect(prep, isNotNull);
      expect(prep!.environment, {'SOME_VAR': '/some/where'});
      expect(prep.engineSha256, 'abc123');
    });

    test('an old tool without the step yields the setup --force message',
        () async {
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async => stubTool(
          'echo \'Could not find a command named "engine-prepare".\' >&2; '
          'exit 64',
        ),
      );

      expect(await run(), isNull);
      verify(
        () => logger.err(any(that: contains('out of date'))),
      ).called(1);
    });

    test('malformed JSON output fails cleanly', () async {
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async => stubToolWritingJson('{ not json'),
      );

      expect(await run(), isNull);
      verify(
        () => logger.err(any(that: contains('invalid result'))),
      ).called(1);
    });

    test('a result missing env or checksum fails cleanly', () async {
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async =>
            stubToolWritingJson(jsonEncode({'env': <String, String>{}})),
      );

      expect(await run(), isNull);
      verify(
        () => logger.err(any(that: contains('invalid result'))),
      ).called(1);
    });

    test('a present-but-unusable tool binary fails cleanly, not a crash',
        () async {
      // No execute bit → Process.runSync throws ProcessException.
      final f = File('${tmp.path}/fcp-tool-stub')
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      when(() => artifacts.ensureBuildTool()).thenAnswer((_) async => f.path);

      expect(await run(), isNull);
      verify(
        () => logger.err(any(that: contains('setup --force'))),
      ).called(1);
    });

    test('a failed engine download is fatal before the tool runs', () async {
      when(() => artifacts.ensureAndroidEngine(
            flutterVersion: any(named: 'flutterVersion'),
          )).thenAnswer((_) async => false);

      expect(await run(), isNull);
      verifyNever(() => artifacts.ensureBuildTool());
    });
  });

  group('finalizeBuild Android short-circuit', () {
    test('skips the tool once the built artifact was verified', () async {
      service.debugSetAndroidEngineVerified(value: true);

      final result = await service.finalizeBuild(
        buildPlatform: 'apk',
        flutterVersion: '3.41.6',
        artifactManager: artifacts,
      );

      expect(result.success, isTrue);
      expect(result.message, contains('verified during build'));
      verifyNever(() => artifacts.ensureBuildTool());
    });

    test('still runs the tool when no verification happened', () async {
      service.debugSetAndroidEngineVerified(value: false);
      when(() => artifacts.ensureBuildTool())
          .thenAnswer((_) async => stubTool('exit 0'));

      final result = await service.finalizeBuild(
        buildPlatform: 'apk',
        flutterVersion: '3.41.6',
        artifactManager: artifacts,
      );

      expect(result.success, isTrue);
      verify(() => artifacts.ensureBuildTool()).called(1);
    });
  });
}
