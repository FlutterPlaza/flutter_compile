import 'dart:async';
import 'dart:convert';

import 'package:flutter_compile/src/daemon/daemon_peer.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';

class MockLogger extends Mock implements Logger {}

void main() {
  group('DaemonPeer', () {
    final tempHome = TempHome();
    late MockLogger logger;

    setUp(() {
      tempHome.setUp();
      logger = MockLogger();
    });

    tearDown(tempHome.tearDown);

    /// Creates a pair of StreamChannels connected to each other.
    /// Returns (clientChannel, daemonChannel) where:
    /// - clientChannel is used by the test to send/receive JSON-RPC
    /// - daemonChannel is used by the DaemonPeer
    ({StreamChannel<String> client, StreamChannel<String> daemon})
    createChannelPair() {
      final clientToServer = StreamController<String>();
      final serverToClient = StreamController<String>();

      final clientChannel = StreamChannel<String>(
        serverToClient.stream,
        clientToServer.sink,
      );

      final daemonChannel = StreamChannel<String>(
        clientToServer.stream,
        serverToClient.sink,
      );

      return (client: clientChannel, daemon: daemonChannel);
    }

    test('version returns current package version', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      // Start peer in background
      unawaited(peer.start());

      // Skip the daemon.connected notification
      // Read until we get a proper response
      final request = {'jsonrpc': '2.0', 'method': 'version', 'id': 1};
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], equals({'version': packageVersion}));
          break;
        }
      }

      // Shutdown
      final shutdownReq = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 2};
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('sdk.list returns list shape', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      unawaited(peer.start());

      final request = {'jsonrpc': '2.0', 'method': 'sdk.list', 'id': 1};
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], isList);
          break;
        }
      }

      final shutdownReq = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 2};
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('sdk.global.get returns null with no config', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      unawaited(peer.start());

      final request = {'jsonrpc': '2.0', 'method': 'sdk.global.get', 'id': 1};
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], equals({'version': null}));
          break;
        }
      }

      final shutdownReq = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 2};
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('config.list returns empty map with no config', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      unawaited(peer.start());

      final request = {'jsonrpc': '2.0', 'method': 'config.list', 'id': 1};
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], isA<Map>());
          expect((msg['result'] as Map), isEmpty);
          break;
        }
      }

      final shutdownReq = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 2};
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('config.set writes to rc file', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      unawaited(peer.start());

      final request = {
        'jsonrpc': '2.0',
        'method': 'config.set',
        'id': 1,
        'params': {'key': 'engine', 'value': '/tmp/engine'},
      };
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(
            msg['result'],
            equals({'key': 'engine_path', 'value': '/tmp/engine'}),
          );
          break;
        }
      }

      final shutdownReq = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 2};
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('shutdown closes peer', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      final peerFuture = peer.start();

      final request = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 1};
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], equals({'ok': true}));
          break;
        }
      }

      // Peer should eventually complete
      await peerFuture.timeout(const Duration(seconds: 5));
    });

    test('invalid method returns JSON-RPC error', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);

      unawaited(peer.start());

      final request = {
        'jsonrpc': '2.0',
        'method': 'nonexistent.method',
        'id': 1,
      };
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['error'], isNotNull);
          break;
        }
      }

      final shutdownReq = {'jsonrpc': '2.0', 'method': 'shutdown', 'id': 2};
      channels.client.sink.add(json.encode(shutdownReq));
    });
  });
}
