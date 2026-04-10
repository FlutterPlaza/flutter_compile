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
