import 'dart:typed_data';

import 'package:flutter_compile/src/shared/binary_diff.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  group('Code Push E2E workflow', () {
    late MockLogger logger;
    late CodePushBuildService buildService;

    setUp(() {
      logger = MockLogger();
      buildService = CodePushBuildService(logger: logger);
    });

    test('release → patch → diff → verify roundtrip', () {
      // Simulate: developer creates a release, then modifies code and
      // creates a patch.

      // 1. "Release" — original app payload
      final releasePayload = Uint8List.fromList(
        List.generate(5000, (i) => (i * 7 + 3) % 256),
      );
      final releaseVmcode = buildService.packageVmcode(releasePayload);

      // Verify release .vmcode is valid
      final extractedRelease = buildService.extractVmcode(releaseVmcode);
      expect(extractedRelease, isNotNull);
      expect(extractedRelease, equals(releasePayload));

      // 2. "Patch" — modified app payload (a few bytes changed)
      final patchPayload = Uint8List.fromList(releasePayload);
      patchPayload[100] = 0xFF;
      patchPayload[2000] = 0xAA;
      patchPayload[4500] = 0xBB;

      // 3. Compute binary diff (what `fcp codepush patch --baseline` does)
      final diff = bsdiff(releasePayload, patchPayload);
      expect(diff.length, lessThan(releasePayload.length));

      // 4. Package diff as .vmcode
      final patchVmcode = buildService.packageVmcode(diff);
      final extractedDiff = buildService.extractVmcode(patchVmcode);
      expect(extractedDiff, isNotNull);

      // 5. On device: apply diff to reconstruct the patched payload
      final reconstructed = bspatch(releasePayload, extractedDiff!);
      expect(reconstructed, equals(patchPayload));
    });

    test('release → patch with signature → verify', () {
      final payload = Uint8List.fromList(
        List.generate(1000, (i) => i % 256),
      );
      final fakeSignature = Uint8List.fromList(
        List.generate(256, (i) => (i * 13) % 256),
      );

      // Package with signature
      final vmcode = buildService.packageVmcode(
        payload,
        signature: fakeSignature,
      );

      // Verify extraction still works with signature
      final extracted = buildService.extractVmcode(vmcode);
      expect(extracted, isNotNull);
      expect(extracted, equals(payload));

      // Verify signature is stored in the file
      final bd = vmcode.buffer.asByteData();
      final sigLen = bd.getUint32(48, Endian.little);
      expect(sigLen, equals(256));

      // Read signature bytes
      final storedSig = vmcode.sublist(52, 52 + sigLen);
      expect(storedSig, equals(fakeSignature));
    });

    test('multiple patches accumulate correctly', () {
      // Simulate multiple sequential patches
      final baseline = Uint8List.fromList(
        List.generate(2000, (i) => i % 256),
      );

      // Patch 1: change byte 500
      final v1 = Uint8List.fromList(baseline);
      v1[500] = 0xFF;
      final diff1 = bsdiff(baseline, v1);

      // Patch 2: change byte 1000 on top of v1
      final v2 = Uint8List.fromList(v1);
      v2[1000] = 0xEE;
      final diff2 = bsdiff(v1, v2);

      // Verify: applying patches sequentially reconstructs final state
      final afterPatch1 = bspatch(baseline, diff1);
      expect(afterPatch1, equals(v1));

      final afterPatch2 = bspatch(afterPatch1, diff2);
      expect(afterPatch2, equals(v2));
    });

    test('hash verification catches corruption', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final vmcode = buildService.packageVmcode(payload);

      // Corrupt a payload byte
      vmcode[vmcode.length - 1] ^= 0xFF;

      // Extraction should fail due to hash mismatch
      final result = buildService.extractVmcode(vmcode);
      expect(result, isNull);
    });

    test('full workflow with empty patch (no changes)', () {
      final payload = Uint8List.fromList(
        List.generate(500, (i) => i % 256),
      );

      // Diff of identical files
      final diff = bsdiff(payload, payload);
      final vmcode = buildService.packageVmcode(diff);
      final extracted = buildService.extractVmcode(vmcode);
      expect(extracted, isNotNull);

      // Applying the diff should produce the original
      final reconstructed = bspatch(payload, extracted!);
      expect(reconstructed, equals(payload));
    });
  });
}
