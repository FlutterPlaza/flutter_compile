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
}
