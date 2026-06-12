import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/commands/config_command.dart';
import 'package:flutter_compile/src/commands/doctor_command.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_list.dart';
import 'package:flutter_compile/src/commands/status_command.dart';
import 'package:flutter_compile/src/daemon/file_watcher.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:mason_logger/mason_logger.dart';
import 'package:stream_channel/stream_channel.dart';

class DaemonPeer {
  DaemonPeer({required Logger logger, StreamChannel<String>? channel})
      : _channel = channel;

  final StreamChannel<String>? _channel;
  late rpc.Peer _peer;
  FileWatcher? _watcher;

  Future<void> start() async {
    final channel = _channel ?? _createStdioChannel();
    _peer = rpc.Peer(channel);

    _registerMethods();
    _startFileWatcher();

    _peer.listen();

    // Send connected notification
    _peer.sendNotification('daemon.connected', {
      'version': packageVersion,
      'pid': pid,
    });

    await _peer.done;
    _watcher?.stop();
  }

  StreamChannel<String> _createStdioChannel() {
    final input = stdin.transform(utf8.decoder).transform(const LineSplitter());
    final output = _StdoutStringSink();
    return StreamChannel<String>(input, output);
  }

  void _registerMethods() {
    _peer.registerMethod('sdk.list', () async {
      return await gatherSdkList();
    });

    _peer.registerMethod('sdk.global.get', () async {
      final version = await F.readGlobalSdkVersion();
      return {'version': version};
    });

    _peer.registerMethod('sdk.global.set', (rpc.Parameters params) async {
      final version = params['version'].asString;
      if (!F.isSdkInstalled(version)) {
        throw rpc.RpcException(
          -32602,
          'Flutter SDK "$version" is not installed.',
        );
      }

      final home = F.homeDir();
      final rcConfigFile = File('$home/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(
        rcConfigFile,
        Constants.globalSdkVersionKey,
        version,
      );

      final sdkPath = F.sdkVersionPath(version);

      // Update shell config with SDK manager PATH block
      await F.updateShellSdkPath(sdkPath);

      return {'version': version};
    });

    _peer.registerMethod('sdk.use.get', (rpc.Parameters params) async {
      String? directory;
      try {
        directory = params['directory'].asString;
      } catch (_) {
        // Parameter not provided, use default
      }
      final version = await F.readProjectSdkVersion(directory);
      return {'version': version};
    });

    _peer.registerMethod('sdk.use.set', (rpc.Parameters params) async {
      final version = params['version'].asString;
      String? directory;
      try {
        directory = params['directory'].asString;
      } catch (_) {
        // Parameter not provided, use default
      }

      if (!F.isSdkInstalled(version)) {
        throw rpc.RpcException(
          -32602,
          'Flutter SDK "$version" is not installed.',
        );
      }

      final dir = directory ?? Directory.current.path;
      final file = File('$dir/${Constants.flutterVersionFile}');
      await file.writeAsString('$version\n');

      return {'version': version};
    });

    _peer.registerMethod('doctor', () async {
      return await gatherDoctorChecks();
    });

    _peer.registerMethod('config.list', () async {
      return await gatherConfig();
    });

    _peer.registerMethod('config.get', (rpc.Parameters params) async {
      final key = normalizeConfigKey(params['key'].asString);
      final home = F.homeDir();
      final rcConfigFile = File('$home/.flutter_compilerc');
      final value = await F.readValueForKeyFromRcConfig(rcConfigFile, key);
      return {'key': key, 'value': value};
    });

    _peer.registerMethod('config.set', (rpc.Parameters params) async {
      final key = normalizeConfigKey(params['key'].asString);
      final value = params['value'].asString;
      final home = F.homeDir();
      final rcConfigFile = File('$home/.flutter_compilerc');
      await F.writeKeyValueToRcConfig(rcConfigFile, key, value);
      return {'key': key, 'value': value};
    });

    _peer.registerMethod('status', () async {
      return await gatherStatus();
    });

    _peer.registerMethod('version', () {
      return {'version': packageVersion};
    });

    _peer.registerMethod('shutdown', () async {
      // Schedule close after returning the response
      Future<void>.delayed(Duration.zero, () async {
        _watcher?.stop();
        await _peer.close();
      });
      return {'ok': true};
    });

    // --- Code Push RPC methods ---

    _peer.registerMethod('codepush.status', (rpc.Parameters params) async {
      final token = await CodePushClient.getStoredToken();
      if (token == null || token.isEmpty) {
        throw rpc.RpcException(-32600, 'Not logged in to code push.');
      }

      String? appId;
      try {
        appId = params['app_id'].asString;
      } catch (_) {
        appId = await CodePushClient.getAppId();
      }
      if (appId == null || appId.isEmpty) {
        throw rpc.RpcException(-32602, 'app_id is required.');
      }

      final serverUrl = await CodePushClient.getServerUrl();
      final client = CodePushClient(serverUrl: serverUrl);
      try {
        final result = await client.listReleases(token: token, appId: appId);
        if (result['status_code'] != 200) {
          throw rpc.RpcException(
            -32603,
            result['error'] as String? ?? 'Server error',
          );
        }
        return result;
      } finally {
        client.close();
      }
    });

    _peer.registerMethod('codepush.account', () async {
      final token = await CodePushClient.getStoredToken();
      if (token == null || token.isEmpty) {
        throw rpc.RpcException(-32600, 'Not logged in to code push.');
      }

      final serverUrl = await CodePushClient.getServerUrl();
      final client = CodePushClient(serverUrl: serverUrl);
      try {
        final result = await client.getAccount(token);
        if (result['status_code'] != 200) {
          throw rpc.RpcException(
            -32603,
            result['error'] as String? ?? 'Server error',
          );
        }
        return result;
      } finally {
        client.close();
      }
    });

    _peer.registerMethod('codepush.patches', (rpc.Parameters params) async {
      final token = await CodePushClient.getStoredToken();
      if (token == null || token.isEmpty) {
        throw rpc.RpcException(-32600, 'Not logged in to code push.');
      }

      final releaseId = params['release_id'].asString;
      final serverUrl = await CodePushClient.getServerUrl();
      final client = CodePushClient(serverUrl: serverUrl);
      try {
        final result = await client.listPatches(
          token: token,
          releaseId: releaseId,
        );
        if (result['status_code'] != 200) {
          throw rpc.RpcException(
            -32603,
            result['error'] as String? ?? 'Server error',
          );
        }
        return result;
      } finally {
        client.close();
      }
    });
  }

  void _startFileWatcher() {
    final home = F.homeDir();
    final rcPath = '$home/.flutter_compilerc';
    final projectVersionPath =
        '${Directory.current.path}/${Constants.flutterVersionFile}';

    _watcher = FileWatcher(
      paths: [rcPath, projectVersionPath],
      onChanged: (path) async {
        if (path == rcPath) {
          // Check if SDK version changed
          final globalVersion = await F.readGlobalSdkVersion();
          final projectVersion = await F.readProjectSdkVersion();
          _peer.sendNotification('sdk.changed', {
            'global': globalVersion,
            'project': projectVersion,
          });

          // Also send config changed
          final config = await gatherConfig();
          _peer.sendNotification('config.changed', config);
        } else {
          // .flutter-version changed
          final globalVersion = await F.readGlobalSdkVersion();
          final projectVersion = await F.readProjectSdkVersion();
          _peer.sendNotification('sdk.changed', {
            'global': globalVersion,
            'project': projectVersion,
          });
        }
      },
    );
    _watcher!.start();
  }
}

class _StdoutStringSink implements StreamSink<String> {
  final _doneCompleter = Completer<void>();

  @override
  void add(String event) {
    stdout.writeln(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    stderr.writeln('Error: $error');
  }

  @override
  Future<void> addStream(Stream<String> stream) {
    return stream.forEach(add);
  }

  @override
  Future<void> close() {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
    return _doneCompleter.future;
  }

  @override
  Future<void> get done => _doneCompleter.future;
}
