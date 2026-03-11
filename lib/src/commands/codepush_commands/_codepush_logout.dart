import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushLogoutSubCommand extends Command<int> {
  CodePushLogoutSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'logout';
  @override
  final String description = 'Clear stored code push credentials.';

  @override
  Future<int> run() async {
    await CodePushClient.clearCredentials();
    _logger.info('Logged out. Credentials cleared.');
    return ExitCode.success.code;
  }
}
