import 'package:flutter_compile/src/tui/tui_keys.dart';
import 'package:test/test.dart';

void main() {
  group('parseKey', () {
    test('arrow up', () {
      expect(parseKey([27, 91, 65]), equals(TuiKey.up));
    });

    test('arrow down', () {
      expect(parseKey([27, 91, 66]), equals(TuiKey.down));
    });

    test('arrow right', () {
      expect(parseKey([27, 91, 67]), equals(TuiKey.right));
    });

    test('arrow left', () {
      expect(parseKey([27, 91, 68]), equals(TuiKey.left));
    });

    test('enter (LF)', () {
      expect(parseKey([10]), equals(TuiKey.enter));
    });

    test('enter (CR)', () {
      expect(parseKey([13]), equals(TuiKey.enter));
    });

    test('escape', () {
      expect(parseKey([27]), equals(TuiKey.escape));
    });

    test('ctrl+C', () {
      expect(parseKey([3]), equals(TuiKey.ctrlC));
    });

    test('tab', () {
      expect(parseKey([9]), equals(TuiKey.tab));
    });

    test('q key', () {
      expect(parseKey([113]), equals(TuiKey.keyQ));
    });

    test('Q key (uppercase)', () {
      expect(parseKey([81]), equals(TuiKey.keyQ));
    });

    test('i key', () {
      expect(parseKey([105]), equals(TuiKey.keyI));
    });

    test('r key', () {
      expect(parseKey([114]), equals(TuiKey.keyR));
    });

    test('d key', () {
      expect(parseKey([100]), equals(TuiKey.keyD));
    });

    test('number keys', () {
      expect(parseKey([49]), equals(TuiKey.key1));
      expect(parseKey([50]), equals(TuiKey.key2));
      expect(parseKey([51]), equals(TuiKey.key3));
      expect(parseKey([52]), equals(TuiKey.key4));
    });

    test('empty bytes returns unknown', () {
      expect(parseKey([]), equals(TuiKey.unknown));
    });

    test('unrecognized single byte returns unknown', () {
      expect(parseKey([255]), equals(TuiKey.unknown));
    });

    test('unrecognized escape sequence returns unknown', () {
      expect(parseKey([27, 91, 99]), equals(TuiKey.unknown));
    });
  });
}
