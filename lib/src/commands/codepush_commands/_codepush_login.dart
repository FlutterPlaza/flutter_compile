import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushLoginSubCommand extends Command<int> {
  CodePushLoginSubCommand(this._logger) {
    argParser
      ..addOption(
        'api-key',
        help: 'API key for authentication.',
      )
      ..addOption(
        'server',
        help: 'Code push server URL.',
        defaultsTo: Constants.codePushDefaultServer,
      );
  }

  final Logger _logger;

  @override
  final String name = 'login';
  @override
  final String description = 'Authenticate with the code push server.';

  @override
  Future<int> run() async {
    final serverUrl =
        argResults?['server'] as String? ?? Constants.codePushDefaultServer;

    // Get API key from flag or prompt.
    var apiKey = argResults?['api-key'] as String?;
    if (apiKey == null || apiKey.isEmpty) {
      apiKey = _logger.prompt('Enter your API key:');
    }

    if (apiKey.isEmpty) {
      _logger.err('API key is required.');
      return ExitCode.usage.code;
    }

    final progress = _logger.progress('Authenticating');
    final client = CodePushClient(serverUrl: serverUrl);

    try {
      final result = await client.login(apiKey);
      final statusCode = result['status_code'] as int;

      if (statusCode != 200) {
        progress.fail('Authentication failed: ${result['error'] ?? 'Unknown error'}');
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
        _logger.info(
          '  Subscription: ${user['has_active_subscription'] == true ? 'Active' : 'Inactive'}',
        );
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed to connect to server: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
