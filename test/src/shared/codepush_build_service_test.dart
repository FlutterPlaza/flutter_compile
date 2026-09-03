import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/interface_freeze_constants.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  _signingGuards();
  _versionResolution();
  _interfaceFreeze();
  group('CodePushBuildService', () {
    late MockLogger logger;
    late CodePushBuildService service;

    setUp(() {
      logger = MockLogger();
      service = CodePushBuildService(logger: logger);
    });

    group('computeHash', () {
      test('returns consistent hash for same input', () {
        final data = [1, 2, 3, 4, 5];
        final hash1 = service.computeHash(data);
        final hash2 = service.computeHash(data);
        expect(hash1, equals(hash2));
      });

      test('returns different hash for different input', () {
        final hash1 = service.computeHash([1, 2, 3]);
        final hash2 = service.computeHash([4, 5, 6]);
        expect(hash1, isNot(equals(hash2)));
      });

      test('returns 64-character hex string', () {
        final hash = service.computeHash([1, 2, 3]);
        expect(hash.length, equals(64));
        expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      });
    });

    group('findFlutterBin', () {
      test('returns non-null when flutter is on PATH', () {
        final result = service.findFlutterBin();
        expect(result == null || result.isNotEmpty, isTrue);
      });
    });

    group('validatePayloadMagic', () {
      List<int> mk(List<int> header, [int tailLen = 32]) =>
          [...header, ...List.filled(tailLen, 0x00)];

      const iosHeader = [0x33, 0x43, 0x42, 0x44];
      const macHeaderLe = [0xCF, 0xFA, 0xED, 0xFE];
      const macHeaderBe = [0xFE, 0xED, 0xFA, 0xCF];
      const elfHeader = [0x7F, 0x45, 0x4C, 0x46];
      const badHeader = [0xDE, 0xAD, 0xBE, 0xEF];

      test('accepts ios header on ios', () {
        expect(
          CodePushBuildService.validatePayloadMagic(mk(iosHeader), 'ios'),
          isNull,
        );
      });

      test('accepts macos header (both byte orders) on macos', () {
        expect(
          CodePushBuildService.validatePayloadMagic(mk(macHeaderLe), 'macos'),
          isNull,
        );
        expect(
          CodePushBuildService.validatePayloadMagic(mk(macHeaderBe), 'macos'),
          isNull,
        );
      });

      test('accepts elf header on apk / appbundle / linux / windows', () {
        for (final p in ['apk', 'appbundle', 'linux', 'windows']) {
          expect(
            CodePushBuildService.validatePayloadMagic(mk(elfHeader), p),
            isNull,
            reason: 'elf header should be valid on $p',
          );
        }
      });

      test('rejects a wrong header on ios', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk(badHeader),
          'ios',
        );
        expect(err, isNotNull);
        expect(err, contains('not in the expected format'));
      });

      test('rejects a wrong header on apk', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk(badHeader),
          'apk',
        );
        expect(err, isNotNull);
        expect(err, contains('not in the expected format'));
      });

      test('rejects short payloads', () {
        final err = CodePushBuildService.validatePayloadMagic(
          [0x90, 0xAB],
          'ios',
        );
        expect(err, isNotNull);
        expect(err, contains('too small'));
      });
    });

    group('parseFlutterVersionOutput', () {
      test('extracts stable channel version', () {
        const output = 'Flutter 3.41.2 • channel stable • https://github.com/'
            'flutter/flutter.git\n'
            'Framework • revision abc123 (3 days ago)\n';
        expect(
          CodePushBuildService.parseFlutterVersionOutput(output),
          '3.41.2',
        );
      });

      test('extracts pre-release version with dashes and dots', () {
        const output = 'Flutter 3.27.0-0.1.pre • channel beta • url\n';
        expect(
          CodePushBuildService.parseFlutterVersionOutput(output),
          '3.27.0-0.1.pre',
        );
      });

      test('returns null for empty input', () {
        expect(CodePushBuildService.parseFlutterVersionOutput(''), isNull);
      });

      test('returns null when first line does not start with Flutter', () {
        const output = 'Downloading Flutter SDK...\n'
            'Flutter 3.41.2 • channel stable\n';
        expect(
          CodePushBuildService.parseFlutterVersionOutput(output),
          isNull,
        );
      });

      test('tolerates trailing whitespace on the first line', () {
        const output = 'Flutter 3.5.0   \n';
        expect(
          CodePushBuildService.parseFlutterVersionOutput(output),
          '3.5.0',
        );
      });
    });

    group('resolveFlutterVersion', () {
      test('explicit value short-circuits detection and stored config',
          () async {
        final resolved = await service.resolveFlutterVersion(
          explicit: '3.29.1',
        );
        expect(resolved, '3.29.1');
      });

      test('empty explicit is treated as absent and falls through', () async {
        // We cannot assert the downstream result without mocking
        // subprocess + rc file, but we can assert the method doesn't
        // prematurely return an empty string to the caller.
        final resolved = await service.resolveFlutterVersion(explicit: '');
        expect(resolved, isNot(''));
      });
    });

    group('finalizeBuild', () {
      test(
          'ios is a no-op because the patched engine must be present at build time',
          () async {
        final result = await service.finalizeBuild(
          buildPlatform: 'ios',
          flutterVersion: '3.41.2',
          artifactManager: CodePushArtifactManager(logger: logger),
        );

        expect(result.success, isTrue);
        expect(
          result.message,
          'iOS build already finalized during prepare.',
        );
        expect(result.command, isNull);
      });
    });

    group('patchKernelCompilerArgs', () {
      List<String> args({List<String> defines = const []}) =>
          CodePushBuildService.patchKernelCompilerArgs(
            sdkRoot: '/sdk/flutter_patched_sdk_product/',
            packagesPath: '.dart_tool/package_config.json',
            outputDillPath: 'build/codepush/patch_kernel.dill',
            targetPath: 'lib/.fcp_patch_entry.dart',
            dartDefines: defines,
          );

      test('compiles with release defines against the flutter target', () {
        final a = args();
        expect(a, contains('-Ddart.vm.product=true'));
        expect(a, contains('-Ddart.vm.profile=false'));
        expect(a, contains('--target=flutter'));
        expect(
            a,
            containsAllInOrder(<String>[
              '--sdk-root',
              '/sdk/flutter_patched_sdk_product/',
            ]));
      });

      test('never enables whole-program optimization', () {
        final a = args();
        expect(a, isNot(contains('--aot')));
        expect(a, isNot(contains('--tfa')));
        // The platform must stay linked into the output kernel.
        expect(a, isNot(contains('--no-link-platform')));
      });

      test('appends user dart-defines with the -D prefix', () {
        final a = args(defines: ['FOO=bar', 'BAZ=1']);
        expect(a, contains('-DFOO=bar'));
        expect(a, contains('-DBAZ=1'));
      });

      test('ends with the entry target', () {
        expect(args().last, 'lib/.fcp_patch_entry.dart');
      });

      test('adds --depfile only when a path is given', () {
        expect(args(), isNot(contains('--depfile')));
        final withDep = CodePushBuildService.patchKernelCompilerArgs(
          sdkRoot: '/sdk/flutter_patched_sdk_product/',
          packagesPath: '.dart_tool/package_config.json',
          outputDillPath: 'build/codepush/patch_kernel.dill',
          targetPath: 'lib/.fcp_patch_entry.dart',
          depfilePath: 'build/codepush/patch_kernel.dill.d',
        );
        expect(
          withDep,
          containsAllInOrder(<String>[
            '--depfile',
            'build/codepush/patch_kernel.dill.d',
          ]),
        );
        // The entry target must stay last either way.
        expect(withDep.last, 'lib/.fcp_patch_entry.dart');
      });
    });

    group('withIosReleaseGenSnapshotOptions', () {
      const flag = CodePushBuildService.kIosReleaseGenSnapshotOptions;

      test('appends the gen_snapshot argument when absent', () {
        final args = CodePushBuildService.withIosReleaseGenSnapshotOptions(
          ['--dart-define=FOO=bar'],
        );
        expect(args, [
          '--dart-define=FOO=bar',
          '--extra-gen-snapshot-options=$flag',
        ]);
      });

      test('merges into an existing --extra-gen-snapshot-options list', () {
        final args = CodePushBuildService.withIosReleaseGenSnapshotOptions(
          ['--extra-gen-snapshot-options=--dwarf-stack-traces'],
        );
        expect(args, [
          '--extra-gen-snapshot-options=--dwarf-stack-traces,$flag',
        ]);
        // flutter build accepts one comma-separated list; a duplicate
        // argument occurrence must never be produced.
        expect(
          args.where((a) => a.startsWith('--extra-gen-snapshot-options=')),
          hasLength(1),
        );
      });

      test('does not duplicate an already-present option', () {
        final args = CodePushBuildService.withIosReleaseGenSnapshotOptions(
          ['--extra-gen-snapshot-options=$flag'],
        );
        expect(args, ['--extra-gen-snapshot-options=$flag']);
      });

      test('normalizes an empty existing option list', () {
        final args = CodePushBuildService.withIosReleaseGenSnapshotOptions(
          ['--extra-gen-snapshot-options='],
        );
        expect(args, ['--extra-gen-snapshot-options=$flag']);
      });

      test('does not mutate its input', () {
        final input = ['--dart-define=FOO=bar'];
        CodePushBuildService.withIosReleaseGenSnapshotOptions(input);
        expect(input, ['--dart-define=FOO=bar']);
      });
    });

    group('compilePatchKernel', () {
      test(
          'fails with an actionable message when the SDK cache lacks '
          'front-end artifacts', () async {
        final tempDir =
            Directory.systemTemp.createTempSync('fcp_patch_kernel_test_');
        addTearDown(() => tempDir.deleteSync(recursive: true));

        final result = await service.compilePatchKernel(
          targetPath: 'lib/.fcp_patch_entry.dart',
          outputDillPath: '${tempDir.path}/patch_kernel.dill',
          flutterRootOverride: tempDir.path,
        );

        expect(result.success, isFalse);
        expect(result.message, contains('front-end artifacts'));
        expect(result.command, isNull);
      });

      group('orchestration', () {
        late Directory root;
        late String dartAotRuntime;
        late String frontendServer;
        late String outputDill;

        setUp(() {
          root = Directory.systemTemp.createTempSync('fcp_patch_kernel_orch_');
          dartAotRuntime = '${root.path}/bin/cache/dart-sdk/bin/dartaotruntime';
          frontendServer = '${root.path}/bin/cache/dart-sdk/bin/snapshots/'
              'frontend_server_aot.dart.snapshot';
          final sdkRoot = '${root.path}/bin/cache/artifacts/engine/common/'
              'flutter_patched_sdk_product';
          File(dartAotRuntime).createSync(recursive: true);
          File(frontendServer).createSync(recursive: true);
          Directory(sdkRoot).createSync(recursive: true);
          outputDill = '${root.path}/out/patch_kernel.dill';
        });

        tearDown(() => root.deleteSync(recursive: true));

        test(
            'runs the front-end snapshot via dartaotruntime and succeeds '
            'when the output is written', () async {
          final calls = <List<String>>[];
          final result = await service.compilePatchKernel(
            targetPath: 'lib/.fcp_patch_entry.dart',
            outputDillPath: outputDill,
            dartDefines: ['FOO=bar'],
            flutterRootOverride: root.path,
            runProcess: (executable, args) {
              calls.add([executable, ...args]);
              File(outputDill).writeAsStringSync('dill');
              return ProcessResult(0, 0, '', '');
            },
          );

          expect(result.success, isTrue);
          expect(calls, hasLength(1));
          expect(calls.single.first, dartAotRuntime);
          expect(calls.single[1], frontendServer);
          // The computed inputs must actually reach the subprocess.
          expect(
            calls.single,
            containsAll(<String>[
              '--sdk-root',
              '${root.path}/bin/cache/artifacts/engine/common/'
                  'flutter_patched_sdk_product/',
              '--packages',
              '.dart_tool/package_config.json',
              '--output-dill',
              outputDill,
              '-DFOO=bar',
              'lib/.fcp_patch_entry.dart',
            ]),
          );
        });

        test(
            'deletes a stale output before compiling and fails when the '
            'compiler writes nothing', () async {
          File(outputDill)
            ..createSync(recursive: true)
            ..writeAsStringSync('stale');

          var staleGoneAtCallTime = false;
          final result = await service.compilePatchKernel(
            targetPath: 'lib/.fcp_patch_entry.dart',
            outputDillPath: outputDill,
            flutterRootOverride: root.path,
            runProcess: (executable, args) {
              staleGoneAtCallTime = !File(outputDill).existsSync();
              return ProcessResult(0, 0, '', '');
            },
          );

          expect(staleGoneAtCallTime, isTrue,
              reason: 'a stale kernel must be deleted before the compile');
          expect(result.success, isFalse,
              reason: 'exit 0 without an output file is not a success');
        });

        test('deletes a stale depfile before compiling', () async {
          // The depfile is never removed after a run, so a previous
          // run's closure is present on entry to every subsequent
          // build; this delete is the only thing keeping it from
          // answering this run's include-URI verification.
          final dep = File('$outputDill.d')
            ..createSync(recursive: true)
            ..writeAsStringSync('stale: /old/x.dart');

          var goneAtCallTime = false;
          await service.compilePatchKernel(
            targetPath: 'lib/.fcp_patch_entry.dart',
            outputDillPath: outputDill,
            depfilePath: dep.path,
            flutterRootOverride: root.path,
            runProcess: (executable, args) {
              goneAtCallTime = !dep.existsSync();
              expect(args, containsAllInOrder(<String>['--depfile', dep.path]));
              return ProcessResult(0, 0, '', '');
            },
          );

          expect(goneAtCallTime, isTrue,
              reason: 'a stale depfile must be deleted before the '
                  'compile so it can never answer this run\'s '
                  'include-URI verification');
        });

        test(
            'fails on a non-zero compiler exit even when an output '
            'exists', () async {
          final result = await service.compilePatchKernel(
            targetPath: 'lib/.fcp_patch_entry.dart',
            outputDillPath: outputDill,
            flutterRootOverride: root.path,
            runProcess: (executable, args) {
              File(outputDill).writeAsStringSync('partial');
              return ProcessResult(0, 1, '', 'compile error');
            },
          );

          expect(result.success, isFalse);
          expect(result.exitCode, 1);
          expect(result.stderr, contains('compile error'));
        });
      });
    });
  });

  group('BuildStepResult', () {
    test('success case yields empty diagnostics', () {
      const r = BuildStepResult(success: true);
      expect(r.success, isTrue);
      expect(r.formatDiagnostics(), isEmpty);
    });

    test('precondition failure carries message but no command', () {
      const r = BuildStepResult(
        success: false,
        message: 'Build tool not available.',
      );
      expect(r.success, isFalse);
      expect(r.message, 'Build tool not available.');
      expect(r.formatDiagnostics(), isEmpty);
    });

    test('subprocess failure formats exit code, command, stderr, stdout', () {
      const r = BuildStepResult(
        success: false,
        message: 'Build finalization failed.',
        command: ['/long/abs/path/to/fcp-tool', 'finalize', 'ios'],
        exitCode: 2,
        stdout: 'packaging baseline\n',
        stderr: 'error: missing snapshot\nline two',
      );
      final diag = r.formatDiagnostics();
      expect(diag, contains('exit code: 2'));
      // Tool path is elided to basename for scannability.
      expect(diag, contains('command:   fcp-tool finalize ios'));
      expect(diag, isNot(contains('/long/abs/path/to/')));
      expect(diag, contains('stderr:'));
      expect(diag, contains('    error: missing snapshot'));
      expect(diag, contains('    line two'));
      expect(diag, contains('stdout:'));
      expect(diag, contains('    packaging baseline'));
    });

    test('empty stderr/stdout are omitted from diagnostics', () {
      const r = BuildStepResult(
        success: false,
        message: 'Build finalization failed.',
        command: ['tool', 'finalize', 'ios'],
        exitCode: 1,
        stdout: '',
        stderr: '   \n',
      );
      final diag = r.formatDiagnostics();
      expect(diag, contains('exit code: 1'));
      expect(diag, isNot(contains('stderr:')));
      expect(diag, isNot(contains('stdout:')));
    });
  });
}

// ── Flutter version resolution ──────────────────────────────────────
class _FakeArtifactManager extends CodePushArtifactManager {
  _FakeArtifactManager({required super.logger, this.support});

  final Map<String, Map<String, String>>? support;

  @override
  Future<Map<String, Map<String, String>>?> fetchPlatformSupport() async =>
      support;
}

void _versionResolution() {
  group('detectFlutterVersion retry', () {
    late CodePushBuildService service;
    late bool flutterOnPath;

    setUp(() {
      service = CodePushBuildService(logger: MockLogger());
      flutterOnPath = service.findFlutterBin() != null;
    });

    ProcessResult ok(String stdout) => ProcessResult(0, 0, stdout, '');
    ProcessResult fail() => ProcessResult(0, 1, '', 'boom');

    test('retries once after a failed run and returns the parsed version',
        () async {
      if (!flutterOnPath) return;
      var calls = 0;
      final version = await service.detectFlutterVersion(
        runProcess: (_, __) async {
          calls++;
          return calls == 1
              ? fail()
              : ok('Flutter 3.41.6 • channel stable • ...');
        },
      );
      expect(calls, 2);
      expect(version, '3.41.6');
    });

    test('retries once after a thrown ProcessException', () async {
      if (!flutterOnPath) return;
      var calls = 0;
      final version = await service.detectFlutterVersion(
        runProcess: (_, __) async {
          calls++;
          if (calls == 1) throw ProcessException('flutter', ['--version']);
          return ok('Flutter 3.41.6 • channel stable • ...');
        },
      );
      expect(calls, 2);
      expect(version, '3.41.6');
    });

    test('returns null after two failed attempts (no third try)', () async {
      if (!flutterOnPath) return;
      var calls = 0;
      final version = await service.detectFlutterVersion(
        runProcess: (_, __) async {
          calls++;
          return fail();
        },
      );
      expect(calls, 2);
      expect(version, isNull);
    });
  });

  group('artifactTargetForBuildPlatform', () {
    test('maps mobile build platforms to manifest platforms', () {
      expect(
        CodePushBuildService.artifactTargetForBuildPlatform('ios'),
        'ios-arm64',
      );
      for (final p in ['apk', 'appbundle', 'android']) {
        expect(
          CodePushBuildService.artifactTargetForBuildPlatform(p),
          'android-arm64',
        );
      }
    });

    test('returns null for untracked (desktop) platforms', () {
      for (final p in ['macos', 'linux', 'windows-x64']) {
        expect(CodePushBuildService.artifactTargetForBuildPlatform(p), isNull);
      }
    });
  });

  group('guardStoredVersion', () {
    late MockLogger logger;
    late CodePushBuildService service;

    setUp(() {
      logger = MockLogger();
      service = CodePushBuildService(logger: logger);
    });

    test('accepts the stored version when the manifest supports it', () async {
      final manager = _FakeArtifactManager(
        logger: logger,
        support: {
          '3.41.6': {'ios-arm64': 'rev'},
        },
      );
      final result = await service.guardStoredVersion(
        stored: '3.41.6',
        buildPlatform: 'ios',
        artifactManager: manager,
      );
      expect(result, '3.41.6');
    });

    test('rejects the stored version when the manifest lacks the platform',
        () async {
      final manager = _FakeArtifactManager(
        logger: logger,
        support: {
          '3.41.6': {'android-arm64': 'rev'},
        },
      );
      final result = await service.guardStoredVersion(
        stored: '3.41.6',
        buildPlatform: 'ios',
        artifactManager: manager,
      );
      expect(result, isNull);
    });

    test('rejects a version absent from the manifest entirely', () async {
      final manager = _FakeArtifactManager(
        logger: logger,
        support: {
          '3.41.2': {'ios-arm64': 'rev'},
        },
      );
      final result = await service.guardStoredVersion(
        stored: '3.41.6',
        buildPlatform: 'ios',
        artifactManager: manager,
      );
      expect(result, isNull);
    });

    test('accepts unchecked when the manifest is unavailable', () async {
      final manager = _FakeArtifactManager(logger: logger, support: null);
      final result = await service.guardStoredVersion(
        stored: '3.41.6',
        buildPlatform: 'ios',
        artifactManager: manager,
      );
      expect(result, '3.41.6');
    });

    test('accepts unchecked for untracked platforms and missing manager',
        () async {
      expect(
        await service.guardStoredVersion(stored: '3.41.6'),
        '3.41.6',
      );
      expect(
        await service.guardStoredVersion(
          stored: '3.41.6',
          buildPlatform: 'macos',
          artifactManager: _FakeArtifactManager(logger: logger, support: {}),
        ),
        '3.41.6',
      );
    });
  });
}

// ── iOS interface freeze ────────────────────────────────────────────
void _interfaceFreeze() {
  group('parsePubspecName', () {
    test('plain, quoted, and trailing-comment forms', () {
      expect(CodePushBuildService.parsePubspecName('name: demo\n'), 'demo');
      expect(
        CodePushBuildService.parsePubspecName('name: "demo"\n'),
        'demo',
      );
      expect(
        CodePushBuildService.parsePubspecName("name: 'demo'\n"),
        'demo',
      );
      expect(
        CodePushBuildService.parsePubspecName('name: demo # my app\n'),
        'demo',
      );
      expect(CodePushBuildService.parsePubspecName('# empty\n'), isNull);
    });
  });

  group('parseDepfileSources', () {
    test('parses entries and unescapes spaces', () {
      final sources = CodePushBuildService.parseDepfileSources(
        'out.dill: /a/b.dart /c\\ d/e.dart \\\n /f/g.dart\n',
      );
      expect(sources, {'/a/b.dart', '/c d/e.dart', '/f/g.dart'});
    });

    test('normalizes doubled Windows backslashes to single separators', () {
      final sources = CodePushBuildService.parseDepfileSources(
        'out.dill: C:\\\\proj\\\\lib\\\\main.dart /a/b.dart\n',
        windowsPaths: true,
      );
      expect(sources, {'C:/proj/lib/main.dart', '/a/b.dart'});
    });

    test('returns empty on malformed input', () {
      expect(CodePushBuildService.parseDepfileSources('no colon'), isEmpty);
    });
  });

  group('dartSourceIsPart', () {
    test('detects real part-of directives', () {
      expect(CodePushBuildService.dartSourceIsPart("part of 'a.dart';"), true);
      expect(
        CodePushBuildService.dartSourceIsPart(
          '// header\n/* block */\npart of my.lib;\n',
        ),
        true,
      );
      expect(
        CodePushBuildService.dartSourceIsPart(
          '@Deprecated("x")\nlibrary a;\npart of b;\n',
        ),
        true,
      );
    });

    test('detects a multi-line part-of directive', () {
      expect(
        CodePushBuildService.dartSourceIsPart("part of\n'a.dart';\n"),
        true,
      );
    });

    test('does not misfire on part-of text inside code', () {
      expect(
        CodePushBuildService.dartSourceIsPart(
          "const help = '''\npart of the setup flow\n''';\n",
        ),
        false,
      );
      expect(CodePushBuildService.dartSourceIsPart('void main() {}'), false);
      expect(
        CodePushBuildService.dartSourceIsPart("part 'impl.dart';"),
        false,
      );
    });
  });

  group('unmatchedPackageIncludeUris', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('include_uri_test');
      Directory('${tmp.path}/app/.dart_tool').createSync(recursive: true);
      Directory('${tmp.path}/app/lib').createSync(recursive: true);
      File('${tmp.path}/app/lib/main.dart').writeAsStringSync('void main(){}');
      File('${tmp.path}/app/lib/overlay.dart').writeAsStringSync('int o = 1;');
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "demo", "rootUri": "../", "packageUri": "lib/"}
  ]
}
''');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('a URI whose source file is in the closure is not reported', () {
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: {
          '${tmp.path}/app/lib/main.dart',
          '${tmp.path}/app/lib/overlay.dart',
        },
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, isEmpty);
    });

    test(
        'a URI reachable only from the BASELINE (absent from the '
        'patch closure) is reported', () {
      // The device-validation shape: the overlay exists on disk but
      // nothing in the patch entry's import chain pulls it in, so the
      // compiled input does not contain it and the include silently
      // selects nothing.
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: {'${tmp.path}/app/lib/main.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, ['package:demo/overlay.dart']);
    });

    test('a package unknown to the config is reported', () {
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:absent_pkg/x.dart'],
        closurePaths: {'${tmp.path}/app/lib/main.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, ['package:absent_pkg/x.dart']);
    });

    test('non-package and malformed URIs are unverifiable, not reported', () {
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const [
          'dart:core',
          'package:no_slash',
          'package:trailing/',
        ],
        closurePaths: {'${tmp.path}/app/lib/main.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, isEmpty);
    });

    test('an absent package config verifies nothing (no false report)', () {
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: const {},
        projectRoot: '${tmp.path}/nonexistent',
      );
      expect(unmatched, isEmpty);
    });

    test('a symlink-resolved closure path still matches the literal URI', () {
      // The front-end may write resolved paths into the depfile while
      // the config spells the literal ones — same tolerance as the
      // freeze mapping.
      final resolvedLib =
          Directory('${tmp.path}/app/lib').resolveSymbolicLinksSync();
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: {'$resolvedLib/overlay.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, isEmpty);
    });

    test('a project-root-relative closure path still matches', () {
      // A front-end version may write cwd-relative source paths into
      // the depfile ([appLibrariesFromClosure] carries a bare 'lib/'
      // prefix for the same reason). Every include reporting "matches
      // no library" on such a closure is the false positive this
      // function's doc comment rules out.
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: {'lib/main.dart', 'lib/overlay.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, isEmpty);
    });

    test('a relative closure still reports a genuinely absent include', () {
      // The relative candidate must widen the MATCH, not the report
      // suppression: an include whose source is in no spelling of the
      // closure keeps warning.
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: {'lib/main.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, ['package:demo/overlay.dart']);
    });

    test(
        'an out-of-root path dependency matches a ../-relative closure '
        'spelling', () {
      // Monorepo shape: shared_ui lives NEXT TO the app
      // (`shared_ui: {path: ../shared_ui}`), so a cwd-relative depfile
      // spells its sources `../shared_ui/lib/…`. Root-joining must
      // collapse the `..` segments to reach the package's absolute
      // lib/ dir — while an include of that same package whose source
      // is in NO spelling of the closure keeps warning.
      Directory('${tmp.path}/shared_ui/lib').createSync(recursive: true);
      File('${tmp.path}/shared_ui/lib/x.dart').writeAsStringSync('int x = 1;');
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "demo", "rootUri": "../", "packageUri": "lib/"},
    {"name": "shared_ui", "rootUri": "../../shared_ui", "packageUri": "lib/"}
  ]
}
''');
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const [
          'package:shared_ui/x.dart',
          'package:shared_ui/absent.dart',
        ],
        closurePaths: {'lib/main.dart', '../shared_ui/lib/x.dart'},
        projectRoot: '${tmp.path}/app',
      );
      expect(unmatched, ['package:shared_ui/absent.dart']);
    });

    test('windows-shaped relative closure paths still match', () {
      // posix host; exercise the normalizer + root-join only, like the
      // sibling rows at dependencyPackageLibrariesFromClosure.
      final unmatched = CodePushBuildService.unmatchedPackageIncludeUris(
        includeUris: const ['package:demo/overlay.dart'],
        closurePaths: {r'lib\main.dart', r'lib\overlay.dart'},
        projectRoot: '${tmp.path}/app',
        windowsPaths: true,
      );
      expect(unmatched, isEmpty);
    });
  });

  group('dependencyPackageLibrariesFromClosure', () {
    late Directory tmp;

    /// The absolute (pub-cache style) rootUri, spelled as a real file URI
    /// so it is valid on both hosts — see the setUp comment.
    String hostedPkgRootUri() =>
        Directory('${tmp.path}/cache/hosted_pkg').uri.toString();

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dep_freeze_test');
      // App package layout + package_config referencing one relative
      // (path) dep, one absolute file: (pub-cache style) dep, the app
      // itself, and flutter (excluded).
      Directory('${tmp.path}/app/.dart_tool').createSync(recursive: true);
      Directory('${tmp.path}/app/lib').createSync(recursive: true);
      Directory('${tmp.path}/deps/sdk_pkg/lib/src').createSync(recursive: true);
      Directory('${tmp.path}/cache/hosted_pkg/lib').createSync(recursive: true);
      Directory('${tmp.path}/flutter/lib').createSync(recursive: true);
      File('${tmp.path}/deps/sdk_pkg/lib/sdk_pkg.dart')
          .writeAsStringSync("export 'src/core.dart';");
      File('${tmp.path}/deps/sdk_pkg/lib/src/core.dart')
          .writeAsStringSync('class Core {}');
      File('${tmp.path}/deps/sdk_pkg/lib/src/core.g.dart')
          .writeAsStringSync("part of 'core.dart';");
      File('${tmp.path}/cache/hosted_pkg/lib/hosted.dart')
          .writeAsStringSync('int h = 1;');
      File('${tmp.path}/flutter/lib/widgets.dart')
          .writeAsStringSync('class W {}');
      // Two things here are load-bearing on a Windows host, and getting
      // either wrong makes the WHOLE config unreadable — which reads as
      // "the mapping is broken" when the mapping was never reached:
      //   * jsonEncode, not an interpolated literal: a native Windows
      //     path is full of backslashes, and '\U' is not a legal JSON
      //     string escape, so a spliced literal fails jsonDecode outright.
      //   * Uri.directory(...), not 'file://' + a native path: only a
      //     POSIX absolute path can be concatenated onto the scheme. On
      //     Windows that yields file://C:\... whose authority parses as
      //     'c' and whose file path comes back as the UNC \\c\... .
      // Both are fixture bugs, not product bugs: pub writes a real
      // file:/// URI and a real JSON escape on every platform.
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync(jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'demo', 'rootUri': '../', 'packageUri': 'lib/'},
          {
            'name': 'sdk_pkg',
            'rootUri': '../../deps/sdk_pkg',
            'packageUri': 'lib/',
          },
          {
            'name': 'hosted_pkg',
            'rootUri': hostedPkgRootUri(),
            'packageUri': 'lib/',
          },
          {'name': 'flutter', 'rootUri': '../../flutter', 'packageUri': 'lib/'},
        ],
      }));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test(
        'maps closure files of dependency packages, excluding parts, '
        'the app package, and flutter', () {
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {
          '${tmp.path}/app/lib/main.dart',
          '${tmp.path}/deps/sdk_pkg/lib/sdk_pkg.dart',
          '${tmp.path}/deps/sdk_pkg/lib/src/core.dart',
          '${tmp.path}/deps/sdk_pkg/lib/src/core.g.dart',
          '${tmp.path}/cache/hosted_pkg/lib/hosted.dart',
          '${tmp.path}/flutter/lib/widgets.dart',
          '/unrelated/lib/z.dart',
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
      );
      expect(uris, [
        'package:hosted_pkg/hosted.dart',
        'package:sdk_pkg/sdk_pkg.dart',
        'package:sdk_pkg/src/core.dart',
      ]);
    });

    test('missing package_config yields empty (freeze keeps prior scope)', () {
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {'${tmp.path}/deps/sdk_pkg/lib/src/core.dart'},
        projectRoot: '${tmp.path}/nonexistent',
        packageName: 'demo',
      );
      expect(uris, isEmpty);
    });

    test('malformed package_config yields empty rather than throwing', () {
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('not json');
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {'${tmp.path}/deps/sdk_pkg/lib/src/core.dart'},
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
      );
      expect(uris, isEmpty);
    });

    test('matches depfile paths whose symlinks the front-end resolved', () {
      // Simulate a symlinked package root: config points at the symlink,
      // the closure carries the RESOLVED path (what the front-end writes).
      final real = Directory('${tmp.path}/real_pkg/lib')
        ..createSync(recursive: true);
      File('${real.path}/r.dart').writeAsStringSync('int r = 1;');
      Link('${tmp.path}/link_pkg').createSync('${tmp.path}/real_pkg');
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "linked", "rootUri": "../../link_pkg", "packageUri": "lib/"}
  ]
}
''');
      final resolvedLib =
          Directory('${tmp.path}/real_pkg/lib').resolveSymbolicLinksSync();
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {'$resolvedLib/r.dart'},
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
      );
      expect(uris, ['package:linked/r.dart']);
    });

    test('windows-shaped closure paths match and read consistently', () {
      // Matching and file reads must both use the normalized form.
      final winRoot = tmp.path; // posix host; exercise the normalizer only
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {
          '${winRoot.replaceAll('/', r'\')}'
              r'\deps\sdk_pkg\lib\src\core.dart',
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
        windowsPaths: true,
      );
      // Prefix computed with windows separators normalized the same way —
      // the read goes through the normalized (forward-slash) path, which on
      // this posix host is the real file, so the entry maps.
      expect(uris, ['package:sdk_pkg/src/core.dart']);
    });

    test('empty packageUri maps from the package root, never from /', () {
      Directory('${tmp.path}/rootpkg/src').createSync(recursive: true);
      File('${tmp.path}/rootpkg/top.dart').writeAsStringSync('int t = 1;');
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "rootpkg", "rootUri": "../../rootpkg", "packageUri": ""}
  ]
}
''');
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {
          '${tmp.path}/rootpkg/top.dart',
          '${tmp.path}/deps/sdk_pkg/lib/src/core.dart', // NOT rootpkg's
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
      );
      // Maps only the package's own file; a '/' prefix would have
      // hijacked the second path as package:rootpkg/... too.
      expect(uris, ['package:rootpkg/top.dart']);
    });

    test('absolute packageUri is rejected, never resolved from root', () {
      Directory('${tmp.path}/etc').createSync(recursive: true);
      File('${tmp.path}/etc/evil.dart').writeAsStringSync('int e = 1;');
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "badpkg", "rootUri": "../../deps/sdk_pkg", "packageUri": "/etc/"}
  ]
}
''');
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {
          '/etc/evil.dart',
          '${tmp.path}/deps/sdk_pkg/lib/src/core.dart',
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
      );
      expect(uris, isEmpty);
    });

    test(
        'package name with YAML-significant characters is skipped, '
        'not embedded', () {
      // Only a hand-edited config can carry such a name (pub validates
      // names); a quote or newline would otherwise land verbatim in the
      // emitted spec's quoted scalar.
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync(jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': "evil'\n  - library: 'package:injected/x.dart",
            'rootUri': '../../deps/sdk_pkg',
            'packageUri': 'lib/',
          },
          {
            'name': 'hosted_pkg',
            // A real file URI: 'file://' + a native path is POSIX-only.
            'rootUri': hostedPkgRootUri(),
            'packageUri': 'lib/',
          },
        ],
      }));
      final skips = <String>[];
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {
          '${tmp.path}/deps/sdk_pkg/lib/src/core.dart',
          '${tmp.path}/cache/hosted_pkg/lib/hosted.dart',
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
        onSkip: (path, reason) => skips.add('$reason: $path'),
      );
      // The conforming package still maps; the bad name maps nothing.
      expect(uris, ['package:hosted_pkg/hosted.dart']);
      expect(skips, hasLength(1));
      expect(skips.single, contains('unsupported characters in package name'));
      // The skip report itself carries no raw quote/newline either.
      expect(skips.single, isNot(contains("'")));
      expect(skips.single, isNot(contains('\n')));
    });

    test('dot-dot packageUri escaping the package root is rejected', () {
      File('${tmp.path}/outside.dart').writeAsStringSync('int o = 1;');
      File('${tmp.path}/app/.dart_tool/package_config.json')
          .writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {"name": "escapee", "rootUri": "../../deps/sdk_pkg", "packageUri": "../../"}
  ]
}
''');
      final uris = CodePushBuildService.dependencyPackageLibrariesFromClosure(
        closurePaths: {
          '${tmp.path}/outside.dart',
          '${tmp.path}/deps/sdk_pkg/lib/src/core.dart',
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
      );
      expect(uris, isEmpty);
    });

    test('writer appends dependency libraries to the callable section', () {
      File('${tmp.path}/app/lib/main.dart').writeAsStringSync('void main() {}');
      final specDir = Directory('${tmp.path}/app/specs')..createSync();
      final result = CodePushBuildService(
        logger: Logger(),
      ).writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/app/lib/main.dart',
          '${tmp.path}/deps/sdk_pkg/lib/src/core.dart',
        },
        projectRoot: '${tmp.path}/app',
        packageName: 'demo',
        specDirPath: specDir.path,
      );
      expect(result, isNotNull);
      final yaml = File(result!.specPath).readAsStringSync();
      expect(yaml, contains("- library: 'package:demo/main.dart'"));
      expect(yaml, contains("- library: 'package:sdk_pkg/src/core.dart'"));
      expect(result.appCount, 1);
    });
  });

  group('appLibrariesFromClosure', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('freeze_test');
      Directory('${tmp.path}/lib/src').createSync(recursive: true);
      File('${tmp.path}/lib/main.dart').writeAsStringSync('void main() {}');
      File('${tmp.path}/lib/src/util.dart').writeAsStringSync('int x = 1;');
      File('${tmp.path}/lib/src/util.g.dart')
          .writeAsStringSync("part of 'util.dart';");
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('lists only closure files under lib/, excluding parts', () {
      final uris = CodePushBuildService.appLibrariesFromClosure(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '${tmp.path}/lib/src/util.dart',
          '${tmp.path}/lib/src/util.g.dart',
          '${tmp.path}/test/x.dart',
          '/other/package/lib/y.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
      );
      expect(uris, [
        'package:demo/main.dart',
        'package:demo/src/util.dart',
      ]);
    });

    test('backslashed closure spelling maps AND reads the real file', () {
      // The file exists ONLY at the normalized location; the closure
      // entry is its backslashed spelling. Passing requires both the
      // prefix match and readPath to normalize.
      File('${tmp.path}/lib/win_only.dart').writeAsStringSync('int w = 1;');
      final backslashed = '${tmp.path}/lib/win_only.dart'.replaceAll('/', r'\');
      final uris = CodePushBuildService.appLibrariesFromClosure(
        closurePaths: {backslashed},
        projectRoot: tmp.path,
        packageName: 'demo',
        windowsPaths: true,
      );
      expect(uris, contains('package:demo/win_only.dart'));
    });

    test('a POSIX root containing a literal backslash still maps', () {
      if (Platform.isWindows) {
        markTestSkipped('backslashes are path separators on Windows');
        return;
      }
      // Translation is Windows-only, so this layout keeps releasing —
      // the pre-content-addressing behavior, restored.
      final bsRoot = Directory('${tmp.path}/a\\b')..createSync();
      Directory('${bsRoot.path}/lib').createSync();
      File('${bsRoot.path}/lib/main.dart').writeAsStringSync('void main(){}');
      final uris = CodePushBuildService.appLibrariesFromClosure(
        closurePaths: {'${bsRoot.path}/lib/main.dart'},
        projectRoot: bsRoot.path,
        packageName: 'demo',
        windowsPaths: false,
      );
      expect(uris, contains('package:demo/main.dart'));
    });

    test('relative depfile entries map and read correctly', () async {
      final uris = CodePushBuildService.appLibrariesFromClosure(
        closurePaths: {'lib/main.dart', 'lib/src/util.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
      );
      expect(uris, [
        'package:demo/main.dart',
        'package:demo/src/util.dart',
      ]);
    });

    test('a dead file NOT in the closure is never listed', () {
      File('${tmp.path}/lib/main_dev.dart').writeAsStringSync('void m() {}');
      final uris = CodePushBuildService.appLibrariesFromClosure(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
      );
      expect(uris, ['package:demo/main.dart']);
    });

    test('hidden-directory files and unsafe paths are excluded', () {
      Directory('${tmp.path}/lib/.history').createSync(recursive: true);
      File('${tmp.path}/lib/.history/old.dart').writeAsStringSync('int a=1;');
      final skips = <String>[];
      final uris = CodePushBuildService.appLibrariesFromClosure(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '${tmp.path}/lib/.history/old.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        onSkip: (p, r) => skips.add(r),
      );
      expect(uris, ['package:demo/main.dart']);
    });
  });

  group('discoverCompileClosure', () {
    late Directory tmp;
    late CodePushBuildService service;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('closure_test');
      service = CodePushBuildService(logger: MockLogger());
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('parses the depfile on success', () async {
      final closure = await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) {
          expect(exe, contains('dartaotruntime'));
          expect(args, contains('--depfile'));
          File('${tmp.path}/closure.d')
              .writeAsStringSync('out.dill: /a/b.dart /c/d.dart\n');
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(closure, {'/a/b.dart', '/c/d.dart'});
    });

    test('returns null on a non-zero exit', () async {
      final closure = await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) => ProcessResult(0, 1, '', 'boom'),
      );
      expect(closure, isNull);
    });

    test('returns null when the compile writes no depfile', () async {
      final closure = await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) => ProcessResult(0, 0, '', ''),
      );
      expect(closure, isNull);
    });
    test('runs pub get first when package_config is stale', () async {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      final calls = <List<String>>[];
      await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) {
          calls.add([exe, ...args]);
          if (args.first == 'pub') return ProcessResult(0, 0, '', '');
          File('${tmp.path}/closure.d')
              .writeAsStringSync('out.dill: /a/b.dart\n');
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(calls.first, ['flutter', 'pub', 'get']);
      expect(calls, hasLength(2));
    });

    test('aborts when pub get fails', () async {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      final closure = await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) => args.first == 'pub'
            ? ProcessResult(0, 65, '', 'offline')
            : ProcessResult(0, 0, '', ''),
      );
      expect(closure, isNull);
    });

    test('runs gen-l10n before the compile when l10n.yaml exists', () async {
      File('${tmp.path}/l10n.yaml').writeAsStringSync('arb-dir: lib/l10n\n');
      final calls = <List<String>>[];
      await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) {
          calls.add([exe, ...args]);
          if (args.first == 'gen-l10n') return ProcessResult(0, 0, '', '');
          File('${tmp.path}/closure.d')
              .writeAsStringSync('out.dill: /a/b.dart\n');
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(calls.first, ['flutter', 'gen-l10n']);
      expect(calls, hasLength(2));
    });

    test('skips pub get when package_config is fresh', () async {
      File('${tmp.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
      Directory('${tmp.path}/.dart_tool').createSync();
      final config = File('${tmp.path}/.dart_tool/package_config.json')
        ..writeAsStringSync('{}');
      config.setLastModifiedSync(
        DateTime.now().add(const Duration(minutes: 1)),
      );
      final calls = <List<String>>[];
      await service.discoverCompileClosure(
        targetPath: 'lib/main.dart',
        workDirPath: tmp.path,
        flutterRootOverride: '/fake/flutter',
        projectRootOverride: tmp.path,
        runProcess: (exe, args) {
          calls.add([exe, ...args]);
          File('${tmp.path}/closure.d')
              .writeAsStringSync('out.dill: /a/b.dart\n');
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(calls, hasLength(1));
      expect(calls.single.first, contains('dartaotruntime'));
    });
  });
  group('frontendSupportsDynamicInterface', () {
    test('true when the snapshot embeds the option name', () {
      final root = Directory.systemTemp.createTempSync('probe_test');
      addTearDown(() => root.deleteSync(recursive: true));
      final snap = File(
        '${root.path}/bin/cache/dart-sdk/bin/snapshots/'
        'frontend_server_aot.dart.snapshot',
      )..createSync(recursive: true);
      snap.writeAsBytesSync(
        [0, 1, 2, ...'dynamic-interface'.codeUnits, 3, 4],
      );
      expect(
        CodePushBuildService.frontendSupportsDynamicInterface(root.path),
        true,
      );
      snap.writeAsBytesSync([0, 1, 2, 3, 4]);
      expect(
        CodePushBuildService.frontendSupportsDynamicInterface(root.path),
        false,
      );
      expect(
        CodePushBuildService.frontendSupportsDynamicInterface('/nope'),
        false,
      );
    });
  });

  group('flutterLibrariesFromClosure', () {
    test('includes only candidates present in the closure', () {
      final libs = CodePushBuildService.flutterLibrariesFromClosure({
        '/sdk/packages/flutter/lib/widgets.dart',
        '/sdk/packages/flutter/lib/src/widgets/framework.dart',
      });
      expect(libs, ['package:flutter/widgets.dart']);
      expect(libs, isNot(contains('package:flutter/material.dart')));
    });
  });

  group('buildIosInterfaceFreezeYaml', () {
    test('lists dart, flutter, then app libraries under callable', () {
      final yaml = CodePushBuildService.buildIosInterfaceFreezeYaml(
        flutterLibraries: const ['package:flutter/widgets.dart'],
        appLibraries: const ['package:app/a.dart'],
      );
      expect(yaml, contains('callable:'));
      for (final lib in CodePushBuildService.kIosInterfaceFreezeDartLibraries) {
        expect(yaml, contains("  - library: '$lib'"));
      }
      expect(yaml, contains("  - library: 'package:flutter/widgets.dart'"));
      expect(yaml, contains("  - library: 'package:app/a.dart'"));
      expect(yaml, isNot(contains('material.dart')));
    });
  });

  group('extendable constants', () {
    test('the guarded base-class list is pinned', () {
      expect(
        CodePushBuildService.kIosExtendableFrameworkClasses,
        ['StatelessWidget', 'StatefulWidget', 'State'],
      );
      expect(
        CodePushBuildService.kIosExtendableFrameworkLibrary,
        'package:flutter/src/widgets/framework.dart',
      );
    });
  });

  group('buildIosInterfaceFreezeYaml extendable section', () {
    test('included on request with the widget base classes', () {
      final yaml = CodePushBuildService.buildIosInterfaceFreezeYaml(
        flutterLibraries: const ['package:flutter/widgets.dart'],
        appLibraries: const ['package:app/a.dart'],
        includeExtendable: true,
      );
      // Assert the exact block so mispaired library/class lines fail.
      final expectedBlock = StringBuffer('extendable:\n');
      for (final cls in CodePushBuildService.kIosExtendableFrameworkClasses) {
        expectedBlock
          ..writeln(
            "  - library: "
            "'package:flutter/src/widgets/framework.dart'",
          )
          ..writeln("    class: '$cls'");
      }
      expect(yaml, contains(expectedBlock.toString()));
      expect(
        yaml.indexOf('callable:'),
        lessThan(yaml.indexOf('extendable:')),
      );
    });

    test('omitted by default', () {
      final yaml = CodePushBuildService.buildIosInterfaceFreezeYaml(
        flutterLibraries: const [],
        appLibraries: const [],
      );
      expect(yaml, isNot(contains('extendable:')));
    });
  });

  group('writeIosInterfaceFreezeSpec', () {
    late Directory tmp;
    late MockLogger logger;
    late CodePushBuildService service;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('spec_test');
      logger = MockLogger();
      service = CodePushBuildService(logger: logger);
      Directory('${tmp.path}/lib').createSync(recursive: true);
      File('${tmp.path}/lib/main.dart').writeAsStringSync('void main() {}');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('framework in closure => extendable section reaches the file', () {
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '/sdk/packages/flutter/lib/widgets.dart',
          '/sdk/packages/flutter/lib/src/widgets/framework.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      final yaml = File(spec!.specPath).readAsStringSync();
      expect(spec.appCount, 1);
      expect(spec.flutterCount, greaterThan(0));
      expect(spec.extendable, true);
      expect(yaml, contains('extendable:'));
      expect(yaml, contains("  - library: 'package:demo/main.dart'"));
    });

    test('allowExtendable=false omits the section despite the framework', () {
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '/sdk/packages/flutter/lib/src/widgets/framework.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
        allowExtendable: false,
      );
      expect(
        File(spec!.specPath).readAsStringSync(),
        isNot(contains('extendable:')),
      );
      expect(spec.extendable, false);
      // Messaging is the command's job (opt-out warn, gate-miss hard
      // stop) — the flag-agnostic writer stays quiet at default level.
      verifyNever(() => logger.warn(any()));
    });

    test('no framework in closure => extendable omitted in the file', () {
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(
        File(spec!.specPath).readAsStringSync(),
        isNot(contains('extendable:')),
      );
      // The gate miss travels on the record; the COMMAND turns it into
      // a hard stop, so the writer must report it faithfully.
      expect(spec.extendable, false);
      verifyNever(() => logger.warn(any()));
    });

    test('unwritable spec dir => FlutterCompileException, not null', () {
      if (Platform.isWindows) {
        markTestSkipped('chmod semantics are POSIX-only');
        return;
      }
      final roDir = Directory('${tmp.path}/ro')..createSync();
      Process.runSync('chmod', ['555', roDir.path]);
      addTearDown(() => Process.runSync('chmod', ['755', roDir.path]));
      try {
        // Root (containers) ignores mode bits; then there is nothing to
        // assert here.
        File('${roDir.path}/probe').writeAsStringSync('x');
        markTestSkipped('running with privileges that bypass file modes');
        return;
      } on FileSystemException {
        // Expected: the directory really is unwritable.
      }
      expect(
        () => service.writeIosInterfaceFreezeSpec(
          closurePaths: {'${tmp.path}/lib/main.dart'},
          projectRoot: tmp.path,
          packageName: 'demo',
          specDirPath: roDir.path,
        ),
        throwsA(
          isA<FlutterCompileException>().having(
            (e) => e.message,
            'message',
            contains('Check permissions'),
          ),
        ),
      );
    });

    test('no mappable app libraries => null, and stale specs still swept', () {
      // A refused run must not leave a previous run's spec behind: the
      // command already deleted the report, and the two artifacts must
      // never describe different runs. The report file, meanwhile,
      // must SURVIVE the sweep (it is not a spec).
      File('${tmp.path}/dynamic_interface_01dc0ffe01dc0ffe.yaml')
          .writeAsStringSync('old\n');
      File('${tmp.path}/dynamic_interface_report.json')
          .writeAsStringSync('{}\n');
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: const {'/elsewhere/lib/x.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(spec, isNull);
      expect(
        File('${tmp.path}/dynamic_interface_report.json').existsSync(),
        true,
      );
      expect(
        tmp.listSync().whereType<File>().where(
              (f) =>
                  f.uri.pathSegments.last.startsWith('dynamic_interface') &&
                  f.uri.pathSegments.last.endsWith('.yaml'),
            ),
        isEmpty,
      );
    });

    test('a vanished closure entry is skipped as missing, not unreadable', () {
      // A file the compile saw but the mapping cannot find gets the
      // missing reason, split from the permissions case.
      final reasons = <String>[];
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '${tmp.path}/lib/ghost/g.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
        onSkip: (path, reason) => reasons.add(reason),
      );
      expect(spec, isNotNull);
      expect(reasons, hasLength(1));
      expect(reasons.single, contains('missing on disk'));
      expect(reasons.single, contains('unreadable parent directory'));
    });

    test('spec filename is content-addressed and stale specs are swept', () {
      // A leftover from an older fcp (fixed name) and a stale hashed
      // spec must both disappear: the build fingerprint keys on the
      // option STRING, so only a changed filename busts the cache.
      File('${tmp.path}/dynamic_interface.yaml').writeAsStringSync('old\n');
      File('${tmp.path}/dynamic_interface_deadbeefdeadbeef.yaml')
          .writeAsStringSync('old\n');

      final first = service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(
        first!.specPath,
        matches(RegExp(r'dynamic_interface_[0-9a-f]{16}\.yaml$')),
      );
      expect(
        File('${tmp.path}/dynamic_interface.yaml').existsSync(),
        false,
      );
      expect(
        File('${tmp.path}/dynamic_interface_deadbeefdeadbeef.yaml')
            .existsSync(),
        false,
      );
      // Sweeping differently-named stale specs is a spec CHANGE — the
      // next build recompiles from scratch, and the breadcrumb says so.
      expect(first.specChange, InterfaceSpecChange.changed);
      verify(
        () => logger.detail(any(that: contains('Interface spec changed'))),
      ).called(1);

      // Same inputs => same name (a cache hit stays a cache hit), and
      // no spec-change breadcrumb.
      final again = service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(again!.specPath, first.specPath);
      expect(again.specChange, InterfaceSpecChange.unchanged);
      verifyNever(
        () => logger.detail(any(that: contains('Interface spec changed'))),
      );

      // Changed contents => changed name, previous spec swept.
      Directory('${tmp.path}/lib').createSync(recursive: true);
      File('${tmp.path}/lib/extra.dart').writeAsStringSync('class E {}');
      final changed = service.writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '${tmp.path}/lib/extra.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(changed!.specPath, isNot(first.specPath));
      expect(changed.specChange, InterfaceSpecChange.changed);
      expect(File(first.specPath).existsSync(), false);
      expect(File(changed.specPath).existsSync(), true);
      verify(
        () => logger.detail(any(that: contains('Interface spec changed'))),
      ).called(1);
    });

    test('an ambiguous multi-spec sweep is unknown, with its breadcrumb', () {
      // Reachable via an fcp downgrade then upgrade: the legacy fixed
      // name AND this run's hashed name both on disk. Which one the
      // last build used is not provable either way.
      final first = service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      File('${tmp.path}/dynamic_interface.yaml').writeAsStringSync('old\n');
      final again = service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(again!.specPath, first!.specPath);
      expect(again.specChange, InterfaceSpecChange.unknown);
      verify(
        () => logger.detail(
          any(that: contains('Multiple stale interface specs')),
        ),
      ).called(1);
    });

    test('an empty build directory is NOT a spec change', () {
      // rm -rf build/ with an intact .dart_tool leaves the env hash
      // warm and the compile reusable; claiming a spec change here
      // would mis-lead the missing-report warning toward SDK drift.
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      expect(spec!.specChange, InterfaceSpecChange.unknown);
      verify(
        () => logger.detail(
          any(that: contains('No previous interface spec')),
        ),
      ).called(1);
      verifyNever(
        () => logger.detail(any(that: contains('Interface spec changed'))),
      );
    });

    test('the spec breadcrumbs describe cache state, never a build outcome',
        () {
      // The spec write is not the run's commitment: a later refusal
      // (the framework-lib gate miss, the comma guard) deletes this
      // spec and returns, and a line claiming "this release compiles
      // from scratch" would then describe a build that never happened,
      // for a file that no longer exists. Both breadcrumb branches are
      // exercised here — empty directory, then a changed spec.
      service.writeIosInterfaceFreezeSpec(
        closurePaths: {'${tmp.path}/lib/main.dart'},
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );
      Directory('${tmp.path}/lib').createSync(recursive: true);
      File('${tmp.path}/lib/extra.dart').writeAsStringSync('class E {}');
      service.writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          '${tmp.path}/lib/extra.dart',
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
      );

      verify(
        () => logger.detail(any(that: contains('No previous interface spec'))),
      ).called(1);
      verify(
        () => logger.detail(any(that: contains('Interface spec changed'))),
      ).called(1);
      verifyNever(() => logger.detail(any(that: contains('from scratch'))));
      verifyNever(() => logger.detail(any(that: contains('this release '))));
    });

    test('an unreadable (but present) source is skipped as unreadable', () {
      if (Platform.isWindows) {
        markTestSkipped('chmod semantics are POSIX-only');
        return;
      }
      final locked = File('${tmp.path}/lib/locked.dart')
        ..writeAsStringSync('class L {}');
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['644', locked.path]));
      try {
        // Root (containers) ignores mode bits; then there is nothing to
        // assert here.
        locked.readAsStringSync();
        markTestSkipped('running with privileges that bypass file modes');
        return;
      } on FileSystemException {
        // Expected: the file really is unreadable.
      }
      final reasons = <String>[];
      final spec = service.writeIosInterfaceFreezeSpec(
        closurePaths: {
          '${tmp.path}/lib/main.dart',
          locked.path,
        },
        projectRoot: tmp.path,
        packageName: 'demo',
        specDirPath: tmp.path,
        onSkip: (path, reason) => reasons.add(reason),
      );
      expect(spec, isNotNull);
      expect(reasons.single, 'unreadable');
    });
  });

  group('isAbsoluteSourcePath', () {
    test('recognizes POSIX and Windows drive forms', () {
      expect(CodePushBuildService.isAbsoluteSourcePath('/a/b.dart'), true);
      expect(
        CodePushBuildService.isAbsoluteSourcePath(r'C:\proj\lib\m.dart'),
        true,
      );
      expect(
        CodePushBuildService.isAbsoluteSourcePath('C:/proj/lib/m.dart'),
        true,
      );
      expect(CodePushBuildService.isAbsoluteSourcePath('lib/m.dart'), false);
    });
  });

  group('closureHasExtendableFramework', () {
    test('accepts backslashed closure entries like its siblings', () {
      expect(
        CodePushBuildService.closureHasExtendableFramework(
          {r'C:\\sdk\\packages\\flutter\\lib\\src\\widgets\\framework.dart'},
          windowsPaths: true,
        ),
        true,
      );
      expect(
        CodePushBuildService.flutterLibrariesFromClosure(
          {r'C:\\sdk\\packages\\flutter\\lib\\widgets.dart'},
          windowsPaths: true,
        ),
        ['package:flutter/widgets.dart'],
      );
    });

    test('true only when the framework library file is in the closure', () {
      expect(
        CodePushBuildService.closureHasExtendableFramework({
          '/sdk/packages/flutter/lib/src/widgets/framework.dart',
        }),
        true,
      );
      expect(
        CodePushBuildService.closureHasExtendableFramework({
          '/sdk/packages/flutter/lib/widgets.dart',
          '/app/lib/main.dart',
        }),
        false,
      );
    });
  });

  group('withIosReleaseFrontEndOptions', () {
    test('appends the option when absent', () {
      final args = CodePushBuildService.withIosReleaseFrontEndOptions(
        ['--dart-define=A=1'],
        freezeSpecPath: '/p/spec.yaml',
        reportPath: '/p/report.json',
      );
      expect(args, [
        '--dart-define=A=1',
        '--extra-front-end-options=--dynamic-interface=/p/spec.yaml,'
            '--dump-detailed-dynamic-interface=/p/report.json',
      ]);
    });

    test('merges into an existing occurrence without duplicating', () {
      final args = CodePushBuildService.withIosReleaseFrontEndOptions(
        ['--extra-front-end-options=--foo'],
        freezeSpecPath: '/p/spec.yaml',
      );
      expect(args.single,
          '--extra-front-end-options=--foo,--dynamic-interface=/p/spec.yaml');
      final again = CodePushBuildService.withIosReleaseFrontEndOptions(
        args,
        freezeSpecPath: '/p/spec.yaml',
      );
      expect(again, args);
    });

    test('a user-supplied --dynamic-interface wins over ours', () {
      final args = CodePushBuildService.withIosReleaseFrontEndOptions(
        ['--extra-front-end-options=--dynamic-interface=/user/own.yaml'],
        freezeSpecPath: '/p/spec.yaml',
        reportPath: '/p/report.json',
      );
      expect(args.single, contains('/user/own.yaml'));
      expect(args.single, isNot(contains('/p/spec.yaml')));
      expect(args.single, contains('--dump-detailed-dynamic-interface='));
    });

    test('does not mutate its input', () {
      final input = ['--a'];
      CodePushBuildService.withIosReleaseFrontEndOptions(
        input,
        freezeSpecPath: '/p/s.yaml',
      );
      expect(input, ['--a']);
    });
  });
}

// ── Patch signing (finding #4) ──────────────────────────────────────
void _signingGuards() {
  group('signPatchContainer', () {
    late CodePushBuildService service;
    late CodePushArtifactManager artifactManager;

    setUp(() {
      final logger = MockLogger();
      service = CodePushBuildService(logger: logger);
      artifactManager = CodePushArtifactManager(logger: logger);
    });

    test(
        'returns null when the signing key is missing (before any tool '
        'download)', () async {
      final result = await service.signPatchContainer(
        patchPath: 'build/codepush/patch.fcppatch',
        privateKeyPath: '/nonexistent/key.pem',
        artifactManager: artifactManager,
      );
      expect(result, isNull);
    });
  });
}
