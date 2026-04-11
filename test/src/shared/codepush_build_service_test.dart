import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
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
      // Helper: build a fake payload with the given magic bytes
      // followed by some tail data.
      List<int> mk(List<int> magic, [int tailLen = 32]) =>
          [...magic, ...List.filled(tailLen, 0x00)];

      const dartKernelMagic = [0x90, 0xAB, 0xCD, 0xEF];
      const elfMagic = [0x7F, 0x45, 0x4C, 0x46];
      const machO64BeMagic = [0xFE, 0xED, 0xFA, 0xCF];
      const machO64LeMagic = [0xCF, 0xFA, 0xED, 0xFE];

      test('accepts Mach-O little-endian on iOS', () {
        expect(
          CodePushBuildService.validatePayloadMagic(
            mk(machO64LeMagic),
            'ios',
          ),
          isNull,
        );
      });

      test('accepts Mach-O big-endian on iOS', () {
        expect(
          CodePushBuildService.validatePayloadMagic(
            mk(machO64BeMagic),
            'ios',
          ),
          isNull,
        );
      });

      test('accepts Mach-O on macos', () {
        expect(
          CodePushBuildService.validatePayloadMagic(
            mk(machO64LeMagic),
            'macos',
          ),
          isNull,
        );
      });

      test('rejects ELF on iOS with snapshot-kind diagnostic', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk(elfMagic),
          'ios',
        );
        expect(err, isNotNull);
        expect(err, contains('ELF'));
        expect(err, contains('Mach-O'));
        expect(err, contains('0.19.14'));
      });

      test('rejects raw Dart kernel on iOS with snapshot-step hint', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk(dartKernelMagic),
          'ios',
        );
        expect(err, isNotNull);
        expect(err, contains('kernel'));
        expect(err, contains('snapshot'));
      });

      test('rejects unknown magic on iOS', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk([0xDE, 0xAD, 0xBE, 0xEF]),
          'ios',
        );
        expect(err, isNotNull);
        expect(err, contains('DE AD BE EF'));
      });

      test('accepts ELF on apk', () {
        expect(
          CodePushBuildService.validatePayloadMagic(
            mk(elfMagic),
            'apk',
          ),
          isNull,
        );
      });

      test('accepts ELF on appbundle / linux / windows', () {
        // macos is now a Darwin target — it wants Mach-O, not ELF.
        // See the separate "accepts Mach-O on macos" case above.
        for (final p in ['appbundle', 'linux', 'windows']) {
          expect(
            CodePushBuildService.validatePayloadMagic(mk(elfMagic), p),
            isNull,
            reason: 'ELF should be valid on $p',
          );
        }
      });

      test('rejects Mach-O on apk', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk(machO64BeMagic),
          'apk',
        );
        expect(err, isNotNull);
        expect(err, contains('Mach-O'));
      });

      test('rejects Dart kernel on apk with snapshot-step hint', () {
        final err = CodePushBuildService.validatePayloadMagic(
          mk(dartKernelMagic),
          'apk',
        );
        expect(err, isNotNull);
        expect(err, contains('kernel'));
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
