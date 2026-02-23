import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SyncEngineSubCommand extends Command<int> {
  SyncEngineSubCommand(this._logger) {
    argParser.addFlag(
      'force',
      abbr: 'f',
      help: 'Force gclient sync with --reset --force (resolves dirty repos)',
      defaultsTo: false,
    );
  }

  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description = 'Sync the Flutter engine contributor repo.';

  @override
  Future<int> run() async {
    final force = argResults?['force'] as bool;
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

    // gclient and git operate on the Flutter repo root (parent of engine dir)
    final flutterRoot = Directory(enginePath).parent.path;

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

    // Prepend depot_tools to PATH
    final syncEnv = <String, String>{};
    final currentPath = Platform.environment['PATH'] ?? '';
    syncEnv['PATH'] =
        '$depotToolsPath${Platform.isWindows ? ';' : ':'}$currentPath';

    // Git remotes are on the Flutter repo root (parent of engine dir)
    try {
      await F.runCommand(
        'git',
        ['fetch', 'upstream'],
        workingDirectory: flutterRoot,
      );
      await F.runCommand(
        'git',
        ['rebase', 'upstream/master'],
        workingDirectory: flutterRoot,
      );
    } on Exception catch (e) {
      _logger.err(
        'Git sync failed: $e\n'
        'You may need to resolve merge conflicts manually in $flutterRoot.',
      );
      return ExitCode.software.code;
    }

    _logger.info('Running gclient sync...'.yellow);

    // Try normal sync first, retry with --force --reset on failure
    if (!force) {
      try {
        await F.runCommand(
          '$depotToolsPath/gclient',
          ['sync'],
          workingDirectory: flutterRoot,
          environment: syncEnv,
        );
        _logger
          ..success('Engine synced successfully.')
          ..info('Run "flutter_compile build engine" to rebuild.');
        return ExitCode.success.code;
      } on Exception catch (e) {
        _logger.warn(
          '\ngclient sync failed: $e\n'
                  'Retrying with --force --reset to resolve dirty repos...\n'
              .yellow,
        );
      }
    }

    // Forced sync
    try {
      _logger.info('Running forced gclient sync...'.yellow);
      await F.runCommand(
        '$depotToolsPath/gclient',
        ['sync', '--force', '--reset', '--delete_unversioned_trees'],
        workingDirectory: enginePath,
        environment: syncEnv,
      );
      _logger
        ..success('Engine synced successfully (forced).')
        ..info('Run "flutter_compile build engine" to rebuild.');
      return ExitCode.success.code;
    } on Exception catch (e) {
      _logger.err(
        '\ngclient sync failed even with --force --reset: $e\n\n'
        'Manual recovery steps:\n'
        '  1. cd $flutterRoot\n'
        '  2. gclient sync --force --reset --delete_unversioned_trees\n'
        '  3. If that fails, delete engine/src and re-run:\n'
        '     rm -rf $enginePath/src\n'
        '     flutter_compile install engine --force\n',
      );
      return ExitCode.software.code;
    }
  }
}
