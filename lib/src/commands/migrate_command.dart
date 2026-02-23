import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template migrate_command}
/// A command that migrates shell PATH exports to the dedicated env file.
/// {@endtemplate}
class MigrateCommand extends Command<int> {
  /// {@macro migrate_command}
  MigrateCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'migrate';

  @override
  final String description =
      'Migrate shell PATH exports to the dedicated env file '
      '(~/.${Constants.envFile}).';

  @override
  Future<int> run() async {
    final shellRcPath = F.getShellConfigPath();
    _logger.info('Reading $shellRcPath ...');

    final result = await F.migrateShellRcToEnvFile();

    if (result.alreadyMigrated) {
      _logger.info('Already migrated — no legacy PATH blocks found.');
    } else {
      _logger.success(
        'Moved ${result.blocksMoved} PATH block(s) to '
        '~/.${Constants.envFile}.',
      );
    }

    if (result.sourceLineAdded) {
      _logger.info('Added source line to $shellRcPath.');
    }

    _logger.info(Constants.platformRestartShell);

    return ExitCode.success.code;
  }
}
