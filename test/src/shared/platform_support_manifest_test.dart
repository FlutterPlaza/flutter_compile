import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class _MockLogger extends Mock implements Logger {}

/// The platform-aware manifest (`versions-v2.json`) and its fallback
/// contract: a missing/empty/malformed v2 must degrade to the flat
/// manifest, never throw, so old servers keep working.
void main() {
  late HttpServer server;
  late CodePushArtifactManager manager;
  String? v2Body;
  String? v1Body;

  setUp(() async {
    v2Body = null;
    v1Body = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) {
      String? body;
      if (req.uri.path == '/versions-v2.json') body = v2Body;
      if (req.uri.path == '/versions.json') body = v1Body;
      if (body == null) {
        req.response.statusCode = HttpStatus.notFound;
      } else {
        req.response
          ..statusCode = HttpStatus.ok
          ..write(body);
      }
      req.response.close();
    });
    manager = CodePushArtifactManager(
      logger: _MockLogger(),
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
  });

  tearDown(() => server.close(force: true));

  const v2 = {
    'schema': 2,
    'updated': '2026-08-10T00:00:00Z',
    'versions': {
      '3.41.6': {
        'platforms': {'android-arm64': 'rev-a'},
      },
      '3.41.2': {
        'platforms': {'ios-arm64': 'rev-i', 'android-arm64': 'rev-b'},
      },
    },
  };

  group('fetchPlatformSupport', () {
    test('parses a well-formed manifest', () async {
      v2Body = jsonEncode(v2);

      final support = await manager.fetchPlatformSupport();

      expect(support, isNotNull);
      expect(support!['3.41.6'], {'android-arm64': 'rev-a'});
      expect(
          support['3.41.2']!.keys, containsAll(['ios-arm64', 'android-arm64']));
    });

    test('absent manifest returns null (fallback signal)', () async {
      expect(await manager.fetchPlatformSupport(), isNull);
    });

    test('malformed shapes degrade to null, never throw', () async {
      for (final bad in [
        'not json at all',
        '[]',
        '{"versions": "nope"}',
        '{"versions": {}}',
        '{"versions": {"3.41.6": {"platforms": "nope"}}}',
      ]) {
        v2Body = bad;
        expect(await manager.fetchPlatformSupport(), isNull,
            reason: 'input: $bad');
      }
    });
  });

  group('isVersionSupportedForPlatform', () {
    test('answers per platform when v2 is present', () async {
      v2Body = jsonEncode(v2);

      expect(
        await manager.isVersionSupportedForPlatform('3.41.6', 'android-arm64'),
        isTrue,
      );
      expect(
        await manager.isVersionSupportedForPlatform('3.41.6', 'ios-arm64'),
        isFalse,
        reason: 'listed version, unlisted platform',
      );
      expect(
        await manager.isVersionSupportedForPlatform('9.9.9', 'android-arm64'),
        isFalse,
      );
    });

    test('falls back to the flat manifest when v2 is absent', () async {
      v1Body = jsonEncode({'3.38.10': 'rev-old'});

      expect(
        await manager.isVersionSupportedForPlatform('3.38.10', 'android-arm64'),
        isTrue,
        reason: 'flat manifest cannot distinguish platforms — old behavior',
      );
      expect(
        await manager.isVersionSupportedForPlatform('9.9.9', 'android-arm64'),
        isFalse,
      );
    });
  });
}
