import 'dart:typed_data';

import 'package:flutter_compile/src/shared/binary_diff.dart';
import 'package:test/test.dart';

void main() {
  // packageVmcode/extractVmcode E2E tests removed — those methods
  // were moved to the fcp-tool binary (see `fcp codepush setup`).
  // Only bsdiff/bspatch roundtrip tests remain.

  group('Code Push binary diff workflow', () {
    test('diff + patch roundtrip reconstructs modified payload', () {
      final baseline = Uint8List.fromList(
        List.generate(5000, (i) => (i * 7 + 3) % 256),
      );

      final modified = Uint8List.fromList(baseline);
      modified[100] = 0xFF;
      modified[2000] = 0xAA;
      modified[4500] = 0xBB;

      final diff = bsdiff(baseline, modified);
      expect(diff.length, lessThan(baseline.length));

      final reconstructed = bspatch(baseline, diff);
      expect(reconstructed, equals(modified));
    });

    test('multiple sequential patches accumulate correctly', () {
      final baseline = Uint8List.fromList(
        List.generate(2000, (i) => i % 256),
      );

      final v1 = Uint8List.fromList(baseline);
      v1[500] = 0xFF;
      final diff1 = bsdiff(baseline, v1);

      final v2 = Uint8List.fromList(v1);
      v2[1000] = 0xEE;
      final diff2 = bsdiff(v1, v2);

      final afterPatch1 = bspatch(baseline, diff1);
      expect(afterPatch1, equals(v1));

      final afterPatch2 = bspatch(afterPatch1, diff2);
      expect(afterPatch2, equals(v2));
    });

    test('diff of identical files produces valid patch', () {
      final payload = Uint8List.fromList(
        List.generate(500, (i) => i % 256),
      );

      final diff = bsdiff(payload, payload);
      final reconstructed = bspatch(payload, diff);
      expect(reconstructed, equals(payload));
    });
  });
}
