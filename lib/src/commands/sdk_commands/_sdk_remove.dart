import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkRemoveSubCommand extends Command<int> {
  SdkRemoveSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'remove';
  @override
  final String description = 'Remove an installed Flutter SDK version.\n\n'
      'Usage: flutter_compile sdk remove <version>\n'
      'Example: flutter_compile sdk remove 3.19.0';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      _logger.err('Please specify a version to remove.');
      printUsage();
      return ExitCode.usage.code;
    }
    final version = rest.first;
    return removeSdk(_logger, version);
  }
}

Future<int> removeSdk(Logger l, String version) async {
  final targetPath = F.getSdkPath(version);
  if (targetPath == null) {
    l.err('Flutter SDK "$version" is not installed.');
    return ExitCode.usage.code;
  }
  final targetDir = Directory(targetPath);

  final trimmed = version.trim();
  final globalVersion = await F.readGlobalSdkVersion();
  final projectVersion = await F.readProjectSdkVersion();

  if (trimmed == projectVersion?.trim()) {
    l.err('Cannot remove "$trimmed": it is pinned by the current project.');
    return ExitCode.usage.code;
  }

  final progress = l.progress('Removing Flutter SDK "$trimmed"');
  await targetDir.delete(recursive: true);
  progress.complete('Flutter SDK "$trimmed" removed.');

  if (trimmed == globalVersion?.trim()) {
    await _removeGlobalSdkConfig(F.homeDir());
    l.info('Cleared global SDK setting (was "$trimmed").');
  }

  return ExitCode.success.code;
}

Future<void> _removeGlobalSdkConfig(String home) async {
  // Remove global_sdk_version key from rc config
  final rcConfigFile = File('$home/.flutter_compilerc');
  if (await rcConfigFile.exists()) {
    final lines = await rcConfigFile.readAsLines();
    final filtered = lines
        .where((line) => !line.startsWith('${Constants.globalSdkVersionKey}:'))
        .toList();
    await rcConfigFile.writeAsString('${filtered.join('\n')}\n');
  }

  // Remove SDK manager PATH block from shell config
  await F.removeShellSdkPath();
}
