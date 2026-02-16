import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
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
  final home = Platform.environment['HOME'] ?? '';
  final targetPath = '$home${Constants.sdkVersionsPath}/$version';
  final targetDir = Directory(targetPath);

  if (!targetDir.existsSync()) {
    l.err('Flutter SDK "$version" is not installed.');
    return ExitCode.usage.code;
  }

  final progress = l.progress('Removing Flutter SDK "$version"');
  await targetDir.delete(recursive: true);
  progress.complete('Flutter SDK "$version" removed.');

  return ExitCode.success.code;
}
