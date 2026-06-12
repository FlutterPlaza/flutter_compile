import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushRollbackSubCommand extends Command<int> {
  CodePushRollbackSubCommand(this._logger) {
    argParser.addOption(
      'patch-id',
      help: 'The patch ID to roll back.',
      mandatory: true,
    );
  }

  final Logger _logger;

  @override
  final String name = 'rollback';
  @override
  final String description = 'Deactivate a patch so devices stop receiving it.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final patchId = argResults?['patch-id'] as String?;
    if (patchId == null || patchId.isEmpty) {
      _logger.err('--patch-id is required.');
      return ExitCode.usage.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = _logger.progress('Rolling back patch $patchId');

    try {
      final result = await client.rollbackPatch(token: token, patchId: patchId);

      final statusCode = result['status_code'] as int;

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode == 404) {
        progress.fail('Patch not found: $patchId');
        return ExitCode.software.code;
      }

      if (statusCode != 200) {
        progress.fail('Error: ${result['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      progress.complete('Patch rolled back');
      _logger.info('  ${result['message']}');

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
