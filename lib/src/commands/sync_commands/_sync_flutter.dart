import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SyncFlutterSubCommand extends Command<int> {
  SyncFlutterSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'flutter';
  @override
  final String description = 'Sync the Flutter framework contributor repo.';

  @override
  Future<int> run() async {
    _logger.info('Syncing Flutter framework...');

    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');

    final flutterPath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.flutterCompile.key,
    );

    if (flutterPath == null) {
      _logger.err(
        'Flutter path not found in config. '
        'Run "flutter_compile install flutter" first.',
      );
      return ExitCode.config.code;
    }

    // The rc config stores the bin path; the repo root is one level up.
    final flutterDir = Directory(flutterPath).parent.path;

    if (!Directory(flutterDir).existsSync()) {
      _logger.err(
        'Flutter directory not found at $flutterDir. '
        'Run "flutter_compile install flutter" first.',
      );
      return ExitCode.config.code;
    }

    await F.runCommand(
      'git',
      ['fetch', 'upstream'],
      workingDirectory: flutterDir,
    );
    await F.runCommand(
      'git',
      ['rebase', 'upstream/master'],
      workingDirectory: flutterDir,
    );

    _logger.info('Running flutter update-packages...');
    await F.runCommand(
      '$flutterPath/flutter',
      ['update-packages'],
      workingDirectory: flutterDir,
    );

    _logger.success('Flutter framework synced successfully.');
    return ExitCode.success.code;
  }
}
