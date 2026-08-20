import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:test/test.dart';

void main() {
  group('CodePushClient.releaseQueryParams', () {
    test('null attestation values are ABSENT, never serialized', () {
      // The one shape unknown-is-not-false exists to prevent: a
      // serialized null would reach the server as the literal string
      // "null", which its tri-state parse reads as a definite value.
      final params = CodePushClient.releaseQueryParams(
        appId: 'app',
        version: '1.0.0',
      );
      expect(params, {'app_id': 'app', 'version': '1.0.0'});
      expect(params.containsKey('interface_freeze'), isFalse);
      expect(params.containsKey('extendable_widgets'), isFalse);
      expect(params.values, isNot(contains('null')));
    });

    test('non-null attestation values serialize as true/false strings', () {
      expect(
        CodePushClient.releaseQueryParams(
          appId: 'app',
          version: '1.0.0',
          flutterVersion: '3.29.3',
          baselineId: 'base-1',
          interfaceFreeze: true,
          extendableWidgets: false,
        ),
        {
          'app_id': 'app',
          'version': '1.0.0',
          'flutter_version': '3.29.3',
          'baseline_id': 'base-1',
          'interface_freeze': 'true',
          'extendable_widgets': 'false',
        },
      );
    });

    test('the mixed shape cannot occur, but each null drops alone', () {
      // interfaceAttestation returns both-null or both-set; the
      // builder must not couple them regardless.
      final params = CodePushClient.releaseQueryParams(
        appId: 'app',
        version: '1.0.0',
        interfaceFreeze: false,
      );
      expect(params['interface_freeze'], 'false');
      expect(params.containsKey('extendable_widgets'), isFalse);
    });
  });

  group('CodePushClient.releaseQueryPath', () {
    test('the id is encoded — the GET twin of releaseQueryParams', () {
      // (encodeQueryComponent encodes a space as '+', per the
      // application/x-www-form-urlencoded rule servers parse.)
      expect(
        CodePushClient.releaseQueryPath('r 1&x=#y'),
        '/api/v1/releases?release_id=r+1%26x%3D%23y',
      );
      expect(
        CodePushClient.releaseQueryPath('r-1'),
        '/api/v1/releases?release_id=r-1',
      );
    });
  });

  group('CodePushClient.parseResponseBody', () {
    test('a body-supplied status_code can never override the HTTP one', () {
      // The spread comes FIRST for exactly this reason: an ordinary
      // REST envelope body would otherwise replace the real status
      // and feed a String to callers reading `as int` — after the
      // row exists on the server.
      final result = CodePushClient.parseResponseBody(
        201,
        '{"status_code": "418", "release": {"id": "r-1"}}',
        contentType: 'application/json',
      );
      expect(result['status_code'], 201);
      expect(result['release'], {'id': 'r-1'});
    });

    test('every branch carries the int HTTP status', () {
      expect(CodePushClient.parseResponseBody(204, '')['status_code'], 204);
      expect(
        CodePushClient.parseResponseBody(
          502,
          '<html>bad gateway</html>',
          contentType: 'text/html',
        )['status_code'],
        502,
      );
      expect(
        CodePushClient.parseResponseBody(
          200,
          '[1, 2]',
          contentType: 'application/json',
        )['status_code'],
        200,
      );
      // The non-object payload is preserved under 'data' — pin the
      // key, not just the status wrapper.
      expect(
        CodePushClient.parseResponseBody(
          200,
          '[1, 2]',
          contentType: 'application/json',
        )['data'],
        [1, 2],
      );
      expect(
        CodePushClient.parseResponseBody(
          200,
          '{broken',
          contentType: 'application/json',
        )['status_code'],
        200,
      );
    });
  });

  group('CodePushClient.asJsonMap', () {
    test('non-object shapes read as null, never throw', () {
      expect(CodePushClient.asJsonMap({'id': 'r-1'}), {'id': 'r-1'});
      expect(CodePushClient.asJsonMap('r-1'), isNull);
      expect(CodePushClient.asJsonMap(['r-1']), isNull);
      expect(CodePushClient.asJsonMap(null), isNull);
      expect(CodePushClient.asJsonMap(42), isNull);
    });
  });

  group('CodePushClient.releaseFromListing', () {
    test('the requested id is the premise — a mismatch is null', () {
      // A server that ignored the release_id filter (unparseable id
      // treated as absent, filter regression, cached list) must
      // degrade to unknown, never to a confident verdict about
      // someone else's release.
      final info = {
        'releases': [
          {'id': 'other-release', 'snapshot_hash': 'a' * 64},
        ],
      };
      expect(
        CodePushClient.releaseFromListing(info, 'wanted-release'),
        isNull,
      );
    });

    test('a matching id passes the release through', () {
      final release = {'id': 'r-1', 'snapshot_hash': 'a' * 64};
      final info = {
        'releases': [release],
      };
      expect(
        CodePushClient.releaseFromListing(info, 'r-1'),
        same(release),
      );
      // UUIDs are case-insensitive identifiers — an upcased or
      // padded spelling of a correct id must still match.
      expect(
        CodePushClient.releaseFromListing(info, 'R-1'),
        same(release),
      );
      expect(
        CodePushClient.releaseFromListing(info, ' r-1 '),
        same(release),
      );
    });

    test(
        'the list is SEARCHED — a filter-ignoring server that sends '
        'the full app listing still yields the wanted release', () {
      final wanted = {'id': 'r-2', 'snapshot_hash': 'b' * 64};
      final info = {
        'releases': [
          {'id': 'r-1'},
          wanted,
          {'id': 'r-3'},
        ],
      };
      expect(
        CodePushClient.releaseFromListing(info, 'r-2'),
        same(wanted),
      );
    });

    test('empty, absent, and id-less listings are null', () {
      expect(
        CodePushClient.releaseFromListing({'releases': <Object?>[]}, 'r-1'),
        isNull,
      );
      expect(CodePushClient.releaseFromListing({}, 'r-1'), isNull);
      expect(
        CodePushClient.releaseFromListing(
          {
            'releases': [<String, dynamic>{}],
          },
          'r-1',
        ),
        isNull,
      );
    });

    test(
        'shape surprises are null, never a throw — the helper is '
        'public without a guarding catch', () {
      expect(
        CodePushClient.releaseFromListing({'releases': 'not-a-list'}, 'r-1'),
        isNull,
      );
      expect(
        CodePushClient.releaseFromListing(
          {
            'releases': ['not-a-map', 42, null],
          },
          'r-1',
        ),
        isNull,
      );
    });
  });
}
