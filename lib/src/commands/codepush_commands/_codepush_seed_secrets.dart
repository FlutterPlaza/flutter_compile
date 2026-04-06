import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushSeedSecretsSubCommand extends Command<int> {
  CodePushSeedSecretsSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'seed-secrets';
  @override
  final String description = 'This command has been moved to a private tool.';

  @override
  Future<int> run() async {
    _logger.err(
      'seed-secrets has been moved to the private admin CLI.\n'
      'Contact the team for access.',
    );
    return ExitCode.software.code;
  }
}
