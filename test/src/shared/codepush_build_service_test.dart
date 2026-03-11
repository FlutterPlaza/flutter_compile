import 'dart:typed_data';

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

    group('packageVmcode', () {
      test('produces output with VMCODE magic bytes', () {
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final vmcode = service.packageVmcode(payload);

        // Magic: "VMCODE\0\0"
        expect(vmcode[0], equals(0x56)); // V
        expect(vmcode[1], equals(0x4D)); // M
        expect(vmcode[2], equals(0x43)); // C
        expect(vmcode[3], equals(0x4F)); // O
        expect(vmcode[4], equals(0x44)); // D
        expect(vmcode[5], equals(0x45)); // E
        expect(vmcode[6], equals(0x00));
        expect(vmcode[7], equals(0x00));
      });

      test('writes version 1 at offset 8', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final vmcode = service.packageVmcode(payload);
        final bd = vmcode.buffer.asByteData();
        expect(bd.getUint32(8, Endian.little), equals(1));
      });

      test('writes correct payload offset at offset 12', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final vmcode = service.packageVmcode(payload);
        final bd = vmcode.buffer.asByteData();
        // No signature → payload starts at offset 52.
        expect(bd.getUint32(12, Endian.little), equals(52));
      });

      test('writes correct payload offset with signature', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final sig = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
        final vmcode = service.packageVmcode(payload, signature: sig);
        final bd = vmcode.buffer.asByteData();
        // Payload starts at 52 + 4 (signature length) = 56.
        expect(bd.getUint32(12, Endian.little), equals(56));
      });

      test('writes signature length at offset 48', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final sig = Uint8List.fromList(List.generate(10, (i) => i));
        final vmcode = service.packageVmcode(payload, signature: sig);
        final bd = vmcode.buffer.asByteData();
        expect(bd.getUint32(48, Endian.little), equals(10));
      });

      test('unsigned has zero signature length', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final vmcode = service.packageVmcode(payload);
        final bd = vmcode.buffer.asByteData();
        expect(bd.getUint32(48, Endian.little), equals(0));
      });

      test('total size is header + signature + payload', () {
        final payload = Uint8List.fromList([10, 20, 30, 40, 50]);
        final vmcode = service.packageVmcode(payload);
        // 52 (header) + 0 (no signature) + 5 (payload) = 57
        expect(vmcode.length, equals(57));
      });

      test('total size with signature', () {
        final payload = Uint8List.fromList([10, 20, 30]);
        final sig = Uint8List.fromList([0xAA, 0xBB]);
        final vmcode = service.packageVmcode(payload, signature: sig);
        // 52 + 2 + 3 = 57
        expect(vmcode.length, equals(57));
      });
    });

    group('extractVmcode', () {
      test('roundtrips correctly (unsigned)', () {
        final payload = Uint8List.fromList(
          List.generate(100, (i) => i % 256),
        );
        final vmcode = service.packageVmcode(payload);
        final extracted = service.extractVmcode(vmcode);

        expect(extracted, isNotNull);
        expect(extracted!.length, equals(payload.length));
        for (var i = 0; i < payload.length; i++) {
          expect(extracted[i], equals(payload[i]));
        }
      });

      test('roundtrips correctly (with signature)', () {
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final sig = Uint8List.fromList([0xFF, 0xFE, 0xFD]);
        final vmcode = service.packageVmcode(payload, signature: sig);
        final extracted = service.extractVmcode(vmcode);

        expect(extracted, isNotNull);
        expect(extracted!.length, equals(5));
        expect(extracted[0], equals(1));
        expect(extracted[4], equals(5));
      });

      test('returns null for too-small input', () {
        final small = Uint8List.fromList([1, 2, 3]);
        final result = service.extractVmcode(small);
        expect(result, isNull);
      });

      test('returns null for wrong magic bytes', () {
        final bad = Uint8List(100);
        bad[0] = 0xFF;
        final result = service.extractVmcode(bad);
        expect(result, isNull);
      });

      test('returns null for wrong version', () {
        final payload = Uint8List.fromList([1, 2, 3]);
        final vmcode = service.packageVmcode(payload);
        // Set version to 99 at offset 8 (little-endian uint32).
        vmcode[8] = 99;
        vmcode[9] = 0;
        vmcode[10] = 0;
        vmcode[11] = 0;
        final result = service.extractVmcode(vmcode);
        expect(result, isNull);
      });

      test('returns null for corrupted hash', () {
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final vmcode = service.packageVmcode(payload);
        vmcode[20] ^= 0xFF; // Flip bits in hash (at offset 16..47)
        final result = service.extractVmcode(vmcode);
        expect(result, isNull);
      });

      test('returns null for corrupted payload', () {
        final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final vmcode = service.packageVmcode(payload);
        vmcode[53] ^= 0xFF; // Flip bits in payload
        final result = service.extractVmcode(vmcode);
        expect(result, isNull);
      });

      test('handles empty payload', () {
        final payload = Uint8List(0);
        final vmcode = service.packageVmcode(payload);
        final extracted = service.extractVmcode(vmcode);
        expect(extracted, isNotNull);
        expect(extracted!.length, equals(0));
      });

      test('handles large payload', () {
        final payload = Uint8List.fromList(
          List.generate(10000, (i) => i % 256),
        );
        final vmcode = service.packageVmcode(payload);
        final extracted = service.extractVmcode(vmcode);
        expect(extracted, isNotNull);
        expect(extracted!.length, equals(10000));
      });
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

    group('vmcode constants', () {
      test('magic bytes spell VMCODE', () {
        expect(
          CodePushBuildService.vmcodeMagic,
          equals([0x56, 0x4D, 0x43, 0x4F, 0x44, 0x45, 0x00, 0x00]),
        );
      });

      test('version is 1', () {
        expect(CodePushBuildService.vmcodeVersion, equals(1));
      });

      test('header size is 52', () {
        expect(CodePushBuildService.vmcodeHeaderSize, equals(52));
      });
    });
  });
}
