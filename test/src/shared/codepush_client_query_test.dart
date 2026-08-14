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
}
