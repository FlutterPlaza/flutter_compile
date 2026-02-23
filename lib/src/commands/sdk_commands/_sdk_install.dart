import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkInstallSubCommand extends Command<int> {
  SdkInstallSubCommand(this._logger) {
    argParser.addFlag(
      'force',
      help: 'Remove existing SDK and re-install from scratch.',
    );
  }

  final Logger _logger;

  @override
  final String name = 'install';
  @override
  final String description = 'Install a Flutter SDK version or channel.\n\n'
      'Usage: flutter_compile sdk install [--force] <version|channel>\n'
      'Examples:\n'
      '  flutter_compile sdk install 3.19.0\n'
      '  flutter_compile sdk install stable\n'
      '  flutter_compile sdk install --force 3.19.0';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      _logger.err('Please specify a version or channel to install.');
      printUsage();
      return ExitCode.usage.code;
    }
    final version = rest.first;
    final force = argResults?['force'] as bool? ?? false;
    return installSdk(_logger, version, force: force);
  }
}

Future<int> installSdk(Logger l, String version, {bool force = false}) async {
  final home = F.homeDir();
  final targetPath = '$home${Constants.sdkVersionsPath}/$version';

  if (!force && F.isValidGitRepo(targetPath)) {
    l.info('Flutter SDK "$version" is already installed at $targetPath');
    return ExitCode.success.code;
  }

  if (force) {
    l.info('Removing existing SDK and re-installing...');
  }

  final progress = l.progress('Installing Flutter SDK "$version"');

  await Directory('$home${Constants.sdkVersionsPath}').create(recursive: true);

  await F.cloneRepository(
    Constants.flutterGitUrl,
    targetPath,
    force: force,
  );

  await F.runCommand(
    'git',
    ['checkout', version],
    workingDirectory: targetPath,
  );

  l.info('Caching Flutter SDK artifacts...');
  await F.runCommand(
    '$targetPath/bin/flutter',
    ['--version'],
    workingDirectory: targetPath,
    environment: F.sdkEnvironment(targetPath),
  );

  progress.complete('Flutter SDK "$version" installed at $targetPath');

  final globalVersion = await F.readGlobalSdkVersion();
  if (globalVersion == null) {
    final rcConfigFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(
      rcConfigFile,
      Constants.globalSdkVersionKey,
      version,
    );
    await F.updateShellSdkPath(targetPath);
    l.info('Set "$version" as global default (first SDK installed).');
  }

  return ExitCode.success.code;
}
