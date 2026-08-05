import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkExecSubCommand extends Command<int> {
  SdkExecSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'exec';
  @override
  final String description =
      'Run a command through the resolved Flutter SDK.\n\n'
      'Resolution order: project .flutter-version → global default.\n\n'
      'Usage: flutter_compile sdk exec <command> [args...]\n'
      'Examples:\n'
      '  flutter_compile sdk exec flutter doctor\n'
      '  flutter_compile sdk exec dart analyze\n'
      '  flutter_compile sdk exec flutter build apk';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      _logger.err('Please specify a command to run.');
      printUsage();
      return ExitCode.usage.code;
    }

    final resolved = await F.resolveActiveSdkVersion();
    if (resolved == null) {
      _logger.err(
        'No SDK version configured. '
        'Run "flutter_compile sdk global <version>" or '
        '"flutter_compile sdk use <version>" first.',
      );
      return ExitCode.usage.code;
    }

    final version = F.normalizeSdkName(resolved);
    if (!F.isSdkInstalled(version)) {
      _logger.err(
        version == Constants.compiledSdkName
            ? 'The contributor environment is not installed. '
                'Run "flutter_compile install flutter" first.'
            : 'Resolved SDK "$version" is not installed. '
                'Run "flutter_compile sdk install $version" first.',
      );
      return ExitCode.usage.code;
    }

    // Resolve through getSdkPath (not the raw canonical path) so the
    // contributor environment and whitespace-recovered directories both
    // execute from the same location that validation checked. Re-check
    // for null: the SDK can vanish between validation and here.
    final sdkPath = F.getSdkPath(version);
    if (sdkPath == null) {
      _logger.err('SDK "$version" is no longer available.');
      return ExitCode.software.code;
    }
    final environment = {
      ...F.sdkEnvironment(sdkPath),
      'PATH': '$sdkPath/bin${F.envPathSeparator}$sdkPath/bin/cache/dart-sdk/bin'
          '${F.envPathSeparator}${Platform.environment['PATH'] ?? ''}',
    };

    _logger.info('Using SDK "$version" at $sdkPath');
    await F.runCommand(
      rest.first,
      rest.skip(1).toList(),
      environment: environment,
    );

    return ExitCode.success.code;
  }
}
