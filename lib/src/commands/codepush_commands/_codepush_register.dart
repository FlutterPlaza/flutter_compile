import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '_codepush_login.dart';

/// `fcp codepush register` — alias for `fcp codepush login`.
///
/// The browser-based login flow auto-creates an account if one doesn't
/// exist. No separate registration step needed.
class CodePushRegisterSubCommand extends Command<int> {
  CodePushRegisterSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'register';
  @override
  final String description =
      'Create an account and authenticate (opens browser).';

  @override
  Future<int> run() async {
    _logger.info('Opening browser to create your account...');
    _logger.info('');
    // Delegate to the login command — it handles everything.
    final login = CodePushLoginSubCommand(_logger);
    return login.run();
  }
}
