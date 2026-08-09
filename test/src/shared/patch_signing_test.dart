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
  group('signPatchContainer with a stub build tool', () {
    late Directory tmp;
    late CodePushBuildService service;
    late _MockArtifactManager artifacts;
    late String patchPath;
    late String keyPath;

    /// Writes an executable stub `fcp-tool` whose `sign` subcommand runs
    /// [script] (a `/bin/sh` body). Returns its path.
    String stubTool(String script) {
      final f = File('${tmp.path}/fcp-tool-stub')
        ..writeAsStringSync('#!/bin/sh\n$script\n');
      Process.runSync('chmod', ['+x', f.path]);
      return f.path;
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sign_test_');
      final logger = _MockLogger();
      service = CodePushBuildService(logger: logger);
      artifacts = _MockArtifactManager();
      patchPath = '${tmp.path}/patch.fcppatch';
      File(patchPath).writeAsBytesSync([1, 2, 3, 4, 5]);
      keyPath = '${tmp.path}/key.pem';
      File(keyPath).writeAsStringSync('-----BEGIN PRIVATE KEY-----');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Future<String?> run() => service.signPatchContainer(
          patchPath: patchPath,
          privateKeyPath: keyPath,
          artifactManager: artifacts,
        );

    test('returns the base64 signature and leaves the signed container', () {
      final sig = base64Encode([9, 9, 9]);
      // The stub "signs" by rewriting the copy, then prints the base64.
      when(() => artifacts.ensureBuildTool()).thenAnswer(
        (_) async => stubTool('printf signed > "\$3"; echo $sig'),
      );

      return run().then((result) {
        expect(result, equals(sig));
        // The signed bytes were swapped in over the original.
        expect(File(patchPath).readAsStringSync(), equals('signed'));
        // No leftover temp file.
        expect(File('$patchPath.signing').existsSync(), isFalse);
      });
    });

    test('returns null and preserves the original when the tool fails', () {
      when(() => artifacts.ensureBuildTool())
          .thenAnswer((_) async => stubTool('echo boom >&2; exit 3'));

      return run().then((result) {
        expect(result, isNull);
        // Original container untouched (atomic: no partial rewrite).
        expect(File(patchPath).readAsBytesSync(), equals([1, 2, 3, 4, 5]));
        expect(File('$patchPath.signing').existsSync(), isFalse);
      });
    });

    test('returns null on empty tool output', () {
      when(() => artifacts.ensureBuildTool())
          .thenAnswer((_) async => stubTool('exit 0'));
      return run().then((r) => expect(r, isNull));
    });

    test('returns null on malformed (non-base64) output', () {
      when(() => artifacts.ensureBuildTool())
          .thenAnswer((_) async => stubTool('echo "!!! not base64 !!!"'));
      return run().then((r) => expect(r, isNull));
    });

    test('returns null when the tool is unavailable', () {
      when(() => artifacts.ensureBuildTool()).thenAnswer((_) async => null);
      return run().then((r) => expect(r, isNull));
    });
  });
}
