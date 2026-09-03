import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/commands/config_command.dart';
import 'package:flutter_compile/src/daemon/daemon_peer.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
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
    ({
      StreamChannel<String> client,
      StreamChannel<String> daemon,
    }) createChannelPair() {
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

    /// Drives ONE request through a fresh daemon and returns the
    /// response message, then shuts the peer down and waits for it.
    ///
    /// The wait is not politeness: `shutdown` is what stops the file
    /// watcher this peer put on `$HOME`, and `tempHome.tearDown`
    /// deletes that directory. Returning before the watcher is gone
    /// leaves it firing `config.changed` on a closed peer.
    Future<Map<String, dynamic>> request(
      String method, {
      Map<String, dynamic>? params,
    }) async {
      final channels = createChannelPair();
      final peer = DaemonPeer(logger: logger, channel: channels.daemon);
      final peerFuture = peer.start();

      channels.client.sink.add(json.encode({
        'jsonrpc': '2.0',
        'method': method,
        'id': 1,
        if (params != null) 'params': params,
      }));

      Map<String, dynamic>? response;
      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        // The `daemon.connected` notification carries no id.
        if (msg['id'] == 1) {
          response = msg;
          channels.client.sink.add(json.encode({
            'jsonrpc': '2.0',
            'method': 'shutdown',
            'id': 2,
          }));
          continue;
        }
        if (msg['id'] == 2) break;
      }

      await peerFuture.timeout(const Duration(seconds: 10));
      if (response == null) {
        throw StateError('daemon closed without answering "$method"');
      }
      return response;
    }

    /// A project root: the anchor `CodePushClient.projectRcFile` walks
    /// up to is a `pubspec.yaml`, not the rc file itself.
    Directory makeProject(String name) {
      final dir = Directory('${tempHome.path}/$name')..createSync();
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $name\n');
      return dir;
    }

    Future<void> writeMachine(String key, String value) =>
        F.writeKeyValueToRcConfig(
          File('${F.homeDir()}/${CodePushClient.rcFileName}'),
          key,
          value,
        );

    Future<void> writeProject(Directory dir, String key, String value) =>
        F.writeKeyValueToRcConfig(
          File('${dir.path}/${CodePushClient.rcFileName}'),
          key,
          value,
        );

    test('version returns current package version', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

      // Start peer in background
      unawaited(peer.start());

      // Skip the daemon.connected notification
      // Read until we get a proper response
      final request = {
        'jsonrpc': '2.0',
        'method': 'version',
        'id': 1,
      };
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], equals({'version': packageVersion}));
          break;
        }
      }

      // Shutdown
      final shutdownReq = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 2,
      };
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('sdk.list returns list shape', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

      unawaited(peer.start());

      final request = {
        'jsonrpc': '2.0',
        'method': 'sdk.list',
        'id': 1,
      };
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], isList);
          break;
        }
      }

      final shutdownReq = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 2,
      };
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('sdk.global.get returns null with no config', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

      unawaited(peer.start());

      final request = {
        'jsonrpc': '2.0',
        'method': 'sdk.global.get',
        'id': 1,
      };
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], equals({'version': null}));
          break;
        }
      }

      final shutdownReq = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 2,
      };
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('config.list returns empty map with no config', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

      unawaited(peer.start());

      final request = {
        'jsonrpc': '2.0',
        'method': 'config.list',
        'id': 1,
      };
      channels.client.sink.add(json.encode(request));

      await for (final line in channels.client.stream) {
        final msg = json.decode(line) as Map<String, dynamic>;
        if (msg.containsKey('id') && msg['id'] == 1) {
          expect(msg['result'], isA<Map>());
          expect((msg['result'] as Map), isEmpty);
          break;
        }
      }

      final shutdownReq = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 2,
      };
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('config.set writes to rc file', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

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

      final shutdownReq = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 2,
      };
      channels.client.sink.add(json.encode(shutdownReq));
    });

    test('shutdown closes peer', () async {
      final channels = createChannelPair();
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

      final peerFuture = peer.start();

      final request = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 1,
      };
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
      final peer = DaemonPeer(
        logger: logger,
        channel: channels.daemon,
      );

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

      final shutdownReq = {
        'jsonrpc': '2.0',
        'method': 'shutdown',
        'id': 2,
      };
      channels.client.sink.add(json.encode(shutdownReq));
    });

    // The RPCs are the IDE's whole view of code push, and this is the
    // surface the per-project app id changed: `directory` selects which
    // file answers, and the advisory payloads are documented as public
    // API in `docs/daemon-api.html`. Asserting the shapes here is what
    // stops the CLI and the daemon drifting apart again — the split
    // that made `config.get` and `codepush.status` disagree about which
    // app a workspace belongs to.
    group('project-scoped config and code push RPCs', () {
      late HttpServer fakeServer;
      late List<String?> appIdsRequested;

      setUp(() async {
        appIdsRequested = <String?>[];
        fakeServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        unawaited(fakeServer.forEach((req) async {
          appIdsRequested.add(req.uri.queryParameters['app_id']);
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(json.encode({'releases': <dynamic>[]}));
          await req.response.close();
        }));
      });

      tearDown(() => fakeServer.close(force: true));

      Future<void> loginAgainstFakeServer() async {
        await CodePushClient.storeToken('test-token');
        await CodePushClient.storeServerUrl(
          'http://${fakeServer.address.address}:${fakeServer.port}',
        );
      }

      test(
          'config.list accepts a params object — the handler took none '
          'before this change', () async {
        await writeMachine(Constants.globalSdkVersionKey, '3.24.0');

        final msg = await request('config.list', params: <String, dynamic>{});

        expect(msg['error'], isNull);
        final result = msg['result'] as Map<String, dynamic>;
        expect(result[Constants.globalSdkVersionKey], '3.24.0');
      });

      test('config.list reports the project override in the documented shape',
          () async {
        final project = makeProject('workspace');
        await writeMachine(Constants.codePushAppIdKey, 'machine-app');
        await writeProject(project, Constants.codePushAppIdKey, 'project-app');

        final msg = await request(
          'config.list',
          params: {'directory': project.path},
        );

        expect(msg['error'], isNull);
        final result = msg['result'] as Map<String, dynamic>;
        // The flat half stays the machine-wide file, exactly as
        // documented — a client rendering rows is not silently handed
        // a different value than `fcp config list` prints.
        expect(result[Constants.codePushAppIdKey], 'machine-app');

        final advisories = result[kConfigAdvisoriesKey] as Map<String, dynamic>;
        final advisory =
            advisories[Constants.codePushAppIdKey] as Map<String, dynamic>;
        expect(advisory['key'], Constants.codePushAppIdKey);
        expect(
          advisory['project_file'],
          '${project.path}/${CodePushClient.rcFileName}',
        );
        expect(advisory['project_value'], 'project-app');
        expect(advisory['message'], isA<String>());
        // The invariant, not the literal: the advisory must echo what
        // the code push commands actually resolve there.
        expect(
          advisory['project_value'],
          await CodePushClient.getAppId(projectDir: project),
        );
      });

      test(
          'config.get carries value AND advisory, and omits it when the '
          'project agrees', () async {
        final overriding = makeProject('overriding');
        final plain = makeProject('plain');
        await writeMachine(Constants.codePushAppIdKey, 'machine-app');
        await writeProject(
            overriding, Constants.codePushAppIdKey, 'project-app');

        final shadowed = await request('config.get', params: {
          'key': Constants.codePushAppIdKey,
          'directory': overriding.path,
        });
        final shadowedResult = shadowed['result'] as Map<String, dynamic>;
        expect(shadowedResult['key'], Constants.codePushAppIdKey);
        expect(shadowedResult['value'], 'machine-app');
        final advisory = shadowedResult['advisory'] as Map<String, dynamic>;
        expect(advisory['project_value'], 'project-app');
        expect(
          advisory['project_file'],
          '${overriding.path}/${CodePushClient.rcFileName}',
        );

        final unshadowed = await request('config.get', params: {
          'key': Constants.codePushAppIdKey,
          'directory': plain.path,
        });
        final unshadowedResult = unshadowed['result'] as Map<String, dynamic>;
        expect(unshadowedResult['value'], 'machine-app');
        // Present only when there is something to say — an advisory on
        // every read is one a client learns to ignore.
        expect(unshadowedResult.containsKey('advisory'), isFalse);
      });

      test('config.set says so when the write it just made is shadowed',
          () async {
        final project = makeProject('workspace');
        await writeProject(project, Constants.codePushAppIdKey, 'project-app');

        final msg = await request('config.set', params: {
          'key': Constants.codePushAppIdKey,
          'value': 'machine-app',
          'directory': project.path,
        });

        expect(msg['error'], isNull);
        final result = msg['result'] as Map<String, dynamic>;
        expect(result['value'], 'machine-app');
        final advisory = result['advisory'] as Map<String, dynamic>;
        expect(advisory['project_value'], 'project-app');

        // The point of the advisory, stated as behaviour: the write
        // landed machine-wide and changed nothing about this project.
        expect(await CodePushClient.getMachineAppId(), 'machine-app');
        expect(
          await CodePushClient.getAppId(projectDir: project),
          'project-app',
        );
      });

      test(
          'codepush.status picks the project id over the machine-wide '
          'mirror, and `directory` is what decides', () async {
        await loginAgainstFakeServer();
        final scoped = makeProject('scoped');
        final unscoped = makeProject('unscoped');
        await writeMachine(Constants.codePushAppIdKey, 'machine-app');
        await writeProject(scoped, Constants.codePushAppIdKey, 'project-app');

        final withOverride = await request(
          'codepush.status',
          params: {'directory': scoped.path},
        );
        expect(withOverride['error'], isNull,
            reason: json.encode(withOverride));
        expect(appIdsRequested.last, 'project-app');

        // Same daemon, same machine file — only `directory` differs, and
        // a project with no file of its own still resolves the mirror.
        final withoutOverride = await request(
          'codepush.status',
          params: {'directory': unscoped.path},
        );
        expect(withoutOverride['error'], isNull);
        expect(appIdsRequested.last, 'machine-app');
      });

      test('codepush.status still lets an explicit app_id win', () async {
        await loginAgainstFakeServer();
        final scoped = makeProject('scoped');
        await writeMachine(Constants.codePushAppIdKey, 'machine-app');
        await writeProject(scoped, Constants.codePushAppIdKey, 'project-app');

        final msg = await request('codepush.status', params: {
          'directory': scoped.path,
          'app_id': 'explicit-app',
        });

        expect(msg['error'], isNull, reason: json.encode(msg));
        expect(appIdsRequested.last, 'explicit-app');
      });

      test('a blank `directory` reads as absent, not as a project root',
          () async {
        await writeMachine(Constants.codePushAppIdKey, 'machine-app');

        final msg = await request('config.get', params: {
          'key': Constants.codePushAppIdKey,
          'directory': '   ',
        });

        expect(msg['error'], isNull);
        final result = msg['result'] as Map<String, dynamic>;
        expect(result['value'], 'machine-app');
      });
    });
  });
}
