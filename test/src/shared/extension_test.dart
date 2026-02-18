import 'package:flutter_compile/src/shared/extension.dart';
import 'package:test/test.dart';

void main() {
  group('ConsoleColor extension', () {
    const text = 'hello';

    test('red wraps string with ANSI red codes', () {
      expect(text.red, equals('\x1B[31mhello\x1B[0m'));
    });

    test('green wraps string with ANSI green codes', () {
      expect(text.green, equals('\x1B[32mhello\x1B[0m'));
    });

    test('yellow wraps string with ANSI yellow codes', () {
      expect(text.yellow, equals('\x1B[33mhello\x1B[0m'));
    });

    test('blue wraps string with ANSI blue codes', () {
      expect(text.blue, equals('\x1B[34mhello\x1B[0m'));
    });

    test('magenta wraps string with ANSI magenta codes', () {
      expect(text.magenta, equals('\x1B[35mhello\x1B[0m'));
    });

    test('cyan wraps string with ANSI cyan codes', () {
      expect(text.cyan, equals('\x1B[36mhello\x1B[0m'));
    });

    test('white wraps string with ANSI white codes', () {
      expect(text.white, equals('\x1B[37mhello\x1B[0m'));
    });

    test('color codes work with empty strings', () {
      expect(''.red, equals('\x1B[31m\x1B[0m'));
    });

    test('color codes work with multiline strings', () {
      const multi = 'line1\nline2';
      expect(multi.green, equals('\x1B[32mline1\nline2\x1B[0m'));
    });
  });
}
