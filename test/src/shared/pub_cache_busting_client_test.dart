import 'dart:async';
import 'dart:convert';

import 'package:flutter_compile/src/shared/pub_cache_busting_client.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Stub that records every outbound request and returns a canned response.
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> sent = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"ok":true}')),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  group('PubCacheBustingClient', () {
    late _RecordingClient inner;
    late PubCacheBustingClient client;

    setUp(() {
      inner = _RecordingClient();
      client = PubCacheBustingClient(inner);
    });

    tearDown(() {
      client.close();
    });

    test('appends a _cb query parameter to the outbound URL', () async {
      await client.get(Uri.parse('https://pub.dev/api/packages/foo'));
      expect(inner.sent, hasLength(1));
      final url = inner.sent.single.url;
      expect(url.queryParameters, contains('_cb'));
      final cb = url.queryParameters['_cb']!;
      expect(int.tryParse(cb), isNotNull, reason: '_cb should be numeric');
    });

    test('preserves existing query parameters alongside _cb', () async {
      await client.get(
        Uri.parse('https://pub.dev/api/packages/foo?ver=latest&lang=en'),
      );
      final params = inner.sent.single.url.queryParameters;
      expect(params['ver'], 'latest');
      expect(params['lang'], 'en');
      expect(params, contains('_cb'));
    });

    test('sets no-cache headers on every request', () async {
      await client.get(Uri.parse('https://pub.dev/api/packages/foo'));
      final headers = inner.sent.single.headers;
      expect(headers['cache-control'], 'no-cache, no-store, max-age=0');
      expect(headers['pragma'], 'no-cache');
    });

    test('two back-to-back requests get different _cb values', () async {
      await client.get(Uri.parse('https://pub.dev/api/packages/foo'));
      // A 1-microsecond gap is enough for microsecondsSinceEpoch to advance,
      // but rely on at least a single microsecond of event-loop progress
      // rather than asserting anything clock-specific.
      await Future<void>.delayed(const Duration(milliseconds: 1));
      await client.get(Uri.parse('https://pub.dev/api/packages/foo'));
      final first = inner.sent[0].url.queryParameters['_cb']!;
      final second = inner.sent[1].url.queryParameters['_cb']!;
      expect(first, isNot(equals(second)));
    });

    test('preserves the HTTP method on the cloned request', () async {
      final req = http.Request(
        'GET',
        Uri.parse('https://pub.dev/api/packages/foo'),
      );
      await client.send(req);
      expect(inner.sent.single.method, 'GET');
    });
  });
}
