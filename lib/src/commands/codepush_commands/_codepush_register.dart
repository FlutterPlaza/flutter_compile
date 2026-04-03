import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:mason_logger/mason_logger.dart';

import '_codepush_login.dart';

/// `fcp codepush register` — alias for `fcp codepush login`.
///
/// The browser-based login flow auto-creates an account if one doesn't
/// exist. No separate registration step needed.
class CodePushRegisterSubCommand extends Command<int> {
  CodePushRegisterSubCommand(this._logger) {
    argParser
      ..addOption(
        'api-key',
        help: 'API key for authentication (skips browser flow).',
      )
      ..addOption(
        'server',
        help: 'Code push server URL.',
        defaultsTo: Constants.codePushDefaultServer,
      );
  }

  final Logger _logger;

  @override
  final String name = 'register';
  @override
  final String description =
      'Create an account and authenticate (opens browser).';
  @override
  final List<String> aliases = ['signup'];

  @override
  Future<int> run() async {
    _logger.info('Opening browser to create your account...');
    _logger.info('');
    final login = CodePushLoginSubCommand(_logger);
    // Forward args to login.
    return login.runWith(
      apiKey: argResults?['api-key'] as String?,
      serverUrl: argResults?['server'] as String?,
    );
  }
}
