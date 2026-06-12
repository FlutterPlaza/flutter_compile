import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushLoginSubCommand extends Command<int> {
  CodePushLoginSubCommand(this._logger) {
    argParser
      ..addOption(
        'api-key',
        help: 'API key for authentication (skips browser flow).',
      )
      ..addOption(
        'server',
        help: 'Code push server URL. Defaults to the value stored in '
            '~/.flutter_compilerc (set by previous login or '
            '`fcp codepush config --server`), or '
            '${Constants.codePushDefaultServer} if unset.',
      );
  }

  final Logger _logger;

  @override
  final String name = 'login';
  @override
  final String description = 'Authenticate with the code push server.';

  @override
  Future<int> run() async {
    final serverUrl = (argResults?['server'] as String?) ??
        await CodePushClient.getServerUrl();

    // If --api-key provided, use the old direct login flow.
    final apiKey = argResults?['api-key'] as String?;
    if (apiKey != null && apiKey.isNotEmpty) {
      return _loginWithApiKey(serverUrl, apiKey);
    }

    // Default: browser-based device authorization flow.
    return _loginWithBrowser(serverUrl);
  }

  /// Called by register command to forward args.
  Future<int> runWith({String? apiKey, String? serverUrl}) async {
    final server = serverUrl ?? await CodePushClient.getServerUrl();
    if (apiKey != null && apiKey.isNotEmpty) {
      return _loginWithApiKey(server, apiKey);
    }
    return _loginWithBrowser(server);
  }

  Future<int> _loginWithBrowser(String serverUrl) async {
    _logger.info('Opening browser for authentication...');
    _logger.info('');

    // Step 1: Request a device code.
    final httpClient = HttpClient();
    try {
      final uri = Uri.parse('$serverUrl/api/v1/auth/device');
      final request = await httpClient.postUrl(uri);
      request.headers.set('Content-Type', 'application/json');
      request.write('{}');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;

      if (response.statusCode != 201) {
        _logger.err('Failed to start login: ${data['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final deviceCode = data['device_code'] as String;
      final userCode = data['user_code'] as String;
      final authorizeUrl = data['authorize_url'] as String;
      final interval = data['interval'] as int? ?? 2;

      // Step 2: Open browser.
      _logger.info('Your authorization code: $userCode');
      _logger.info('');
      _logger.info(
        'Authorization URL (click or copy to use a different browser):',
      );
      _logger.info('  $authorizeUrl');
      _logger.info('');

      try {
        await _openBrowser(authorizeUrl);
        _logger.info('Browser opened. Authorize the CLI there.');
      } catch (_) {
        _logger.info(
          'Could not open browser automatically — use the URL above.',
        );
      }

      _logger.info('');
      final progress = _logger.progress('Waiting for authorization');

      // Step 3: Poll for completion.
      for (var i = 0; i < 300 ~/ interval; i++) {
        await Future<void>.delayed(Duration(seconds: interval));

        final pollUri = Uri.parse(
          '$serverUrl/api/v1/auth/device?device_code=$deviceCode',
        );
        final pollReq = await httpClient.getUrl(pollUri);
        final pollRes = await pollReq.close();
        final pollBody = await pollRes.transform(utf8.decoder).join();
        final pollData = json.decode(pollBody) as Map<String, dynamic>;

        final status = pollData['status'] as String? ?? '';

        if (status == 'complete') {
          final token = pollData['token'] as String;
          await CodePushClient.storeToken(token);
          await CodePushClient.storeServerUrl(serverUrl);
          progress.complete('Authenticated successfully');

          final user = pollData['user'] as Map<String, dynamic>?;
          if (user != null) {
            _logger.info('  Email: ${user['email']}');
            _logger.info('  Tier:  ${user['tier']}');
          }
          return ExitCode.success.code;
        }

        if (status == 'expired') {
          progress.fail(
            'Authorization expired. Run "fcp codepush login" again.',
          );
          return ExitCode.software.code;
        }

        // status == 'pending' — keep polling.
      }

      progress.fail('Timed out waiting for authorization.');
      return ExitCode.software.code;
    } catch (e) {
      _logger.err('Login failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }

  Future<int> _loginWithApiKey(String serverUrl, String apiKey) async {
    final progress = _logger.progress('Authenticating');
    final client = CodePushClient(serverUrl: serverUrl);

    try {
      final result = await client.login(apiKey);
      final statusCode = result['status_code'] as int;

      if (statusCode != 200) {
        progress.fail(
          'Authentication failed: ${result['error'] ?? 'Unknown error'}',
        );
        return ExitCode.software.code;
      }

      final token = result['token'] as String;
      await CodePushClient.storeToken(token);
      await CodePushClient.storeServerUrl(serverUrl);

      progress.complete('Authenticated successfully');

      final user = result['user'] as Map<String, dynamic>?;
      if (user != null) {
        _logger.info('  Email: ${user['email']}');
        _logger.info('  Tier:  ${user['tier']}');
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed to connect to server: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }

  Future<void> _openBrowser(String url) async {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('start', [url], runInShell: true);
    }
  }
}
