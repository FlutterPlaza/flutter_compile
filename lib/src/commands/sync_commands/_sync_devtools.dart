import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SyncDevtoolsSubCommand extends Command<int> {
  SyncDevtoolsSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'devtools';
  @override
  final String description = 'Sync the DevTools contributor repo.';

  @override
  Future<int> run() async {
    _logger.info('Syncing DevTools...');

    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');

    final devtoolsPath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.devTools.key,
    );

    if (devtoolsPath == null) {
      _logger.err(
        'DevTools path not found in config. '
        'Run "flutter_compile install devtools" first.',
      );
      return ExitCode.config.code;
    }

    if (!Directory(devtoolsPath).existsSync()) {
      _logger.err(
        'DevTools directory not found at $devtoolsPath. '
        'Run "flutter_compile install devtools" first.',
      );
      return ExitCode.config.code;
    }

    await F.runCommand('git', [
      'fetch',
      'upstream',
    ], workingDirectory: devtoolsPath);
    await F.runCommand('git', [
      'rebase',
      'upstream/master',
    ], workingDirectory: devtoolsPath);

    _logger.success('DevTools synced successfully.');
    return ExitCode.success.code;
  }
}
