import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushAccountSubCommand extends Command<int> {
  CodePushAccountSubCommand(this._logger) {
    argParser.addFlag(
      'json',
      help: 'Output as JSON.',
      negatable: false,
    );
  }

  final Logger _logger;

  @override
  final String name = 'account';
  @override
  final String description = 'Show subscription status and account info.';

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;

    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      if (asJson) {
        _logger.info(json.encode({'logged_in': false}));
        return ExitCode.success.code;
      }
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = asJson ? null : _logger.progress('Fetching account info');

    try {
      final result = await client.getAccount(token);
      final statusCode = result['status_code'] as int;

      if (statusCode == 401) {
        if (asJson) {
          _logger.info(json.encode({'logged_in': false}));
          return ExitCode.success.code;
        }
        progress?.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 200) {
        if (asJson) {
          // --json contract: structured output exits 0, callers inspect the
          // `error` field instead of the process status.
          _logger.info(json.encode({
            'logged_in': false,
            'error': result['error'] ?? 'Unknown',
          }));
          return ExitCode.success.code;
        }
        progress?.fail('Error: ${result['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final user = result['user'] as Map<String, dynamic>?;
      final apps = result['apps'] as List<dynamic>?;

      if (asJson) {
        _logger.info(json.encode({
          'logged_in': true,
          'email': user?['email'],
          'name': user?['name'],
          'tier': user?['tier'],
          'has_active_subscription': user?['has_active_subscription'] ?? false,
          'apps': apps ?? [],
        }));
        return ExitCode.success.code;
      }

      progress?.complete('Account info');

      if (user != null) {
        _logger.info('');
        _logger.info('  Email:        ${user['email']}');
        if (user['name'] != null) {
          _logger.info('  Name:         ${user['name']}');
        }
        _logger.info('  Tier:         ${user['tier']}');
        _logger.info(
          '  Subscription: ${user['has_active_subscription'] == true ? 'Active' : 'Inactive (upgrade at flutterplaza.com/pricing)'}',
        );
      }

      if (apps != null && apps.isNotEmpty) {
        _logger.info('');
        _logger.info('  Apps:');
        for (final app in apps) {
          final a = app as Map<String, dynamic>;
          _logger.info('    - ${a['name']} (${a['id']})');
        }
      }

      return ExitCode.success.code;
    } catch (e) {
      if (asJson) {
        _logger.info(json.encode({'logged_in': false, 'error': '$e'}));
        return ExitCode.success.code;
      }
      progress?.fail('Failed to connect: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
