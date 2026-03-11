import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushAccountSubCommand extends Command<int> {
  CodePushAccountSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'account';
  @override
  final String description = 'Show subscription status and account info.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = _logger.progress('Fetching account info');

    try {
      final result = await client.getAccount(token);
      final statusCode = result['status_code'] as int;

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 200) {
        progress.fail('Error: ${result['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      progress.complete('Account info');

      final user = result['user'] as Map<String, dynamic>?;
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

      final apps = result['apps'] as List<dynamic>?;
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
      progress.fail('Failed to connect: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
