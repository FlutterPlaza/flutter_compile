import 'package:flutter_compile/src/shared/exception.dart';
import 'package:test/test.dart';

void main() {
  group('FlutterCompileException', () {
    test('stores message and exit code', () {
      const exception = FlutterCompileException('test error', exitCode: 42);
      expect(exception.message, 'test error');
      expect(exception.exitCode, 42);
    });

    test('toString returns the message', () {
      const exception = FlutterCompileException('something failed');
      expect(exception.toString(), 'something failed');
    });

    test('exit code defaults to null', () {
      const exception = FlutterCompileException('no code');
      expect(exception.exitCode, isNull);
    });

    test('implements Exception', () {
      const exception = FlutterCompileException('test');
      expect(exception, isA<Exception>());
    });
  });
}
