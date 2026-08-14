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
