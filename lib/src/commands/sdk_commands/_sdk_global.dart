import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkGlobalSubCommand extends Command<int> {
  SdkGlobalSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'global';
  @override
  final String description =
      'Set or show the global default Flutter SDK version.\n\n'
      'Usage: flutter_compile sdk global [version]\n'
      'Examples:\n'
      '  flutter_compile sdk global           # Show current global version\n'
      '  flutter_compile sdk global 3.19.0    # Set global default';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      return _showGlobalVersion();
    }
    final version = rest.first;
    return _setGlobalVersion(version);
  }

  Future<int> _showGlobalVersion() async {
    final globalVersion = await F.readGlobalSdkVersion();
    if (globalVersion == null) {
      _logger.info('No global SDK version set.');
      _logger.info('\nRun "flutter_compile sdk global <version>" to set one.');
    } else {
      _logger.info('Global SDK version: $globalVersion');
    }
    return ExitCode.success.code;
  }

  Future<int> _setGlobalVersion(String version) async {
    final sdkPath = F.getSdkPath(version);
    if (sdkPath == null || !F.isFlutterSdk(sdkPath)) {
      _logger.err(
        'Flutter SDK "$version" is not installed. '
        'Run "flutter_compile sdk install $version" first.',
      );
      return ExitCode.usage.code;
    }

    final trimmed = version.trim();
    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(
      rcConfigFile,
      Constants.globalSdkVersionKey,
      trimmed,
    );

    // Update shell config with SDK manager PATH block
    await F.updateShellSdkPath(sdkPath);

    // Update the `default` symlink
    await F.updateDefaultSdkLink(sdkPath);

    _logger.success('Global SDK version set to "$trimmed".');
    _logger.info(Constants.platformRestartShell);

    return ExitCode.success.code;
  }
}
