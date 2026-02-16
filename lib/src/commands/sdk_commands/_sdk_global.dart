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
      _logger.info(
        '\nRun "flutter_compile sdk global <version>" to set one.',
      );
    } else {
      _logger.info('Global SDK version: $globalVersion');
    }
    return ExitCode.success.code;
  }

  Future<int> _setGlobalVersion(String version) async {
    if (!F.isSdkInstalled(version)) {
      _logger.err(
        'Flutter SDK "$version" is not installed. '
        'Run "flutter_compile sdk install $version" first.',
      );
      return ExitCode.usage.code;
    }

    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');
    await F.writeKeyValueToRcConfig(
      rcConfigFile,
      Constants.globalSdkVersionKey,
      version,
    );

    final sdkPath = F.sdkVersionPath(version);
    final pubCachePath = F.sdkPubCachePath(sdkPath);

    // Update shell config with SDK manager PATH block
    final configPath = F.getShellConfigPath();
    final configFile = File(configPath);
    var contents = await configFile.readAsString();

    // Remove any existing SDK manager block
    final sdkManagerPattern = RegExp(
      r'\n# >>> Added by flutter_compile SDK manager >>>'
      r'[\s\S]*?'
      r'# <<< Added by flutter_compile SDK manager <<<\n',
    );
    contents = contents.replaceAll(sdkManagerPattern, '');

    // Append new SDK manager block
    final pathExport = Constants.sdkPATHExport
        .replaceAll('{{path}}', sdkPath)
        .replaceAll('{{pub_cache_path}}', pubCachePath);
    contents += pathExport;
    await configFile.writeAsString(contents);

    _logger.success('Global SDK version set to "$version".');
    _logger.info(
      Constants.restartShell
          .replaceAll('{{shell}}', configPath.split('/').last),
    );

    return ExitCode.success.code;
  }
}
