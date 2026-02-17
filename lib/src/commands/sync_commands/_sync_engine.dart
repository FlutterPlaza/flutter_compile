import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SyncEngineSubCommand extends Command<int> {
  SyncEngineSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description = 'Sync the Flutter engine contributor repo.';

  @override
  Future<int> run() async {
    _logger.info('Syncing Flutter engine...');

    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');

    final enginePath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.engine.key,
    );

    if (enginePath == null) {
      _logger.err(
        'Engine path not found in config. '
        'Run "flutter_compile install engine" first.',
      );
      return ExitCode.config.code;
    }

    if (!Directory(enginePath).existsSync()) {
      _logger.err(
        'Engine directory not found at $enginePath. '
        'Run "flutter_compile install engine" first.',
      );
      return ExitCode.config.code;
    }

    final depotToolsPath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.depotTools.key,
    );

    if (depotToolsPath == null) {
      _logger.err(
        'depot_tools path not found in config. '
        'Run "flutter_compile install engine" first.',
      );
      return ExitCode.config.code;
    }

    final engineSrcFlutter = '$enginePath/src/flutter';

    await F.runCommand(
      'git',
      ['fetch', 'upstream'],
      workingDirectory: engineSrcFlutter,
    );
    await F.runCommand(
      'git',
      ['rebase', 'upstream/main'],
      workingDirectory: engineSrcFlutter,
    );

    _logger.info('Running gclient sync...');
    await F.runCommand(
      '$depotToolsPath/gclient',
      ['sync'],
      workingDirectory: enginePath,
    );

    _logger
      ..success('Engine synced successfully.')
      ..info(
        'Run "flutter_compile build engine" to rebuild.',
      );
    return ExitCode.success.code;
  }
}
