import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushAppsSubCommand extends Command<int> {
  CodePushAppsSubCommand(this._logger) {
    addSubcommand(_AppsListCommand(_logger));
    addSubcommand(_AppsCreateCommand(_logger));
  }

  final Logger _logger;

  @override
  final String name = 'apps';
  @override
  final String description = 'List and manage your apps.';

  @override
  Future<int> run() async {
    _logger.info(description);
    _logger.info('');
    _logger.info('Subcommands:');
    _logger.info('  list     List all apps on your account');
    _logger.info('  create   Create a new app');
    return ExitCode.success.code;
  }
}

class _AppsListCommand extends Command<int> {
  _AppsListCommand(this._logger);
  final Logger _logger;

  @override
  final String name = 'list';
  @override
  final String description = 'List all apps on your account.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final progress = _logger.progress('Fetching apps');

    final httpClient = HttpClient();
    try {
      final uri = Uri.parse('$serverUrl/api/v1/apps');
      final request = await httpClient.getUrl(uri);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Accept', 'application/json');

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;

      if (response.statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (response.statusCode != 200) {
        progress.fail('Error: ${data['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final apps = (data['apps'] as List?) ?? [];
      progress.complete('${apps.length} app(s) found');

      if (apps.isEmpty) {
        _logger.info('  No apps yet. Run "fcp codepush init" to create one.');
      } else {
        _logger.info('');
        for (final app in apps) {
          final a = app as Map<String, dynamic>;
          _logger.info(
            '  ${a['name']} — ${a['id']} '
            '(${a['platform'] ?? 'all'})',
          );
        }
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }
}

class _AppsCreateCommand extends Command<int> {
  _AppsCreateCommand(this._logger) {
    argParser
      ..addOption('name', help: 'App name.', mandatory: true)
      ..addOption('platform', help: 'Target platform (android, ios, etc).');
  }

  final Logger _logger;

  @override
  final String name = 'create';
  @override
  final String description = 'Create a new app on the server.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final appName = argResults?['name'] as String?;
    final platform = argResults?['platform'] as String?;

    if (appName == null || appName.isEmpty) {
      _logger.err('--name is required.');
      return ExitCode.usage.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final progress = _logger.progress('Creating app "$appName"');

    final httpClient = HttpClient();
    try {
      final uri = Uri.parse('$serverUrl/api/v1/apps');
      final request = await httpClient.postUrl(uri);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Content-Type', 'application/json');
      request.write(json.encode({
        'name': appName,
        if (platform != null) 'platform': platform,
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;

      if (response.statusCode == 403) {
        progress
            .fail(data['message'] ?? 'App limit reached. Upgrade your plan.');
        return ExitCode.software.code;
      }

      if (response.statusCode != 201) {
        progress.fail('Error: ${data['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final app = data['app'] as Map<String, dynamic>?;
      progress.complete('App created');
      if (app != null) {
        _logger.info('  App ID: ${app['id']}');
        _logger.info('  Name:   ${app['name']}');
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }
}
