import 'dart:typed_data';

import 'package:flutter_compile/src/shared/binary_diff.dart';
import 'package:test/test.dart';

void main() {
  group('bsdiff/bspatch', () {
    test('roundtrip with identical data produces empty-ish diff', () {
      final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
      final diff = bsdiff(data, data);
      final restored = bspatch(data, diff);
      expect(restored, equals(data));
    });

    test('roundtrip with single byte change', () {
      final old = Uint8List.fromList(List.generate(500, (i) => i % 256));
      final updated = Uint8List.fromList(old);
      updated[250] = (old[250] + 1) % 256;

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with appended data', () {
      final old = Uint8List.fromList([1, 2, 3, 4, 5]);
      final updated = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with truncated data', () {
      final old = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final updated = Uint8List.fromList([1, 2, 3, 4, 5]);

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with completely different data', () {
      final old = Uint8List.fromList(List.generate(100, (i) => i));
      final updated = Uint8List.fromList(List.generate(100, (i) => 255 - i));

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with empty old file', () {
      final old = Uint8List(0);
      final updated = Uint8List.fromList([1, 2, 3, 4, 5]);

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with empty new file', () {
      final old = Uint8List.fromList([1, 2, 3, 4, 5]);
      final updated = Uint8List(0);

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with both empty', () {
      final old = Uint8List(0);
      final updated = Uint8List(0);

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('roundtrip with large data (10KB)', () {
      final old = Uint8List.fromList(
        List.generate(10240, (i) => (i * 7 + 13) % 256),
      );
      final updated = Uint8List.fromList(old);
      // Modify scattered bytes
      for (var i = 0; i < updated.length; i += 100) {
        updated[i] = (updated[i] + 42) % 256;
      }

      final diff = bsdiff(old, updated);
      expect(diff.length, lessThan(old.length)); // Diff should be smaller

      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });

    test('diff of similar data is smaller than full file', () {
      final old = Uint8List.fromList(
        List.generate(5000, (i) => (i * 3) % 256),
      );
      final updated = Uint8List.fromList(old);
      updated[100] = 0xFF;
      updated[2500] = 0xFF;

      final diff = bsdiff(old, updated);
      expect(diff.length, lessThan(old.length ~/ 2));
    });

    test('bspatch rejects invalid magic bytes', () {
      final old = Uint8List.fromList([1, 2, 3]);
      final badPatch = Uint8List.fromList(
        List.generate(100, (i) => 0),
      );

      expect(
        () => bspatch(old, badPatch),
        throwsA(isA<FormatException>()),
      );
    });

    test('bspatch rejects too-small patch', () {
      final old = Uint8List.fromList([1, 2, 3]);
      final tinyPatch = Uint8List.fromList([1, 2]);

      expect(
        () => bspatch(old, tinyPatch),
        throwsA(isA<FormatException>()),
      );
    });

    test('diff has BSDIFF50 magic header', () {
      final old = Uint8List.fromList([1, 2, 3]);
      final updated = Uint8List.fromList([4, 5, 6]);

      final diff = bsdiff(old, updated);
      // BSDIFF50 magic
      expect(diff[0], equals(0x42)); // B
      expect(diff[1], equals(0x53)); // S
      expect(diff[2], equals(0x44)); // D
      expect(diff[3], equals(0x49)); // I
      expect(diff[4], equals(0x46)); // F
      expect(diff[5], equals(0x46)); // F
      expect(diff[6], equals(0x35)); // 5
      expect(diff[7], equals(0x30)); // 0
    });

    test('roundtrip with repeated patterns', () {
      final old = Uint8List.fromList(
        List.generate(1000, (i) => i % 4),
      );
      final updated = Uint8List.fromList(
        List.generate(1000, (i) => (i + 1) % 4),
      );

      final diff = bsdiff(old, updated);
      final restored = bspatch(old, diff);
      expect(restored, equals(updated));
    });
  });
}
