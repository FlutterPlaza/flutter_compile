import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkUseSubCommand extends Command<int> {
  SdkUseSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'use';
  @override
  final String description =
      'Pin a Flutter SDK version for the current project.\n\n'
      'Usage: flutter_compile sdk use [version]\n'
      'Examples:\n'
      '  flutter_compile sdk use            # Show pinned version\n'
      '  flutter_compile sdk use 3.19.0     # Pin version for this project';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      return _showProjectVersion();
    }
    final version = rest.first;
    return _setProjectVersion(version);
  }

  Future<int> _showProjectVersion() async {
    final projectVersion = await F.readProjectSdkVersion();
    if (projectVersion == null) {
      _logger.info(
        'No project SDK version set '
        '(no ${Constants.flutterVersionFile} found).',
      );
      _logger.info(
        '\nRun "flutter_compile sdk use <version>" to pin one.',
      );
    } else {
      _logger.info('Project SDK version: $projectVersion');
    }
    return ExitCode.success.code;
  }

  Future<int> _setProjectVersion(String version) async {
    if (!F.isSdkInstalled(version)) {
      _logger.err(
        'Flutter SDK "$version" is not installed. '
        'Run "flutter_compile sdk install $version" first.',
      );
      return ExitCode.usage.code;
    }

    final file =
        File('${Directory.current.path}/${Constants.flutterVersionFile}');
    await file.writeAsString('$version\n');

    _logger.success(
      'Project SDK version pinned to "$version" '
      'in ${Constants.flutterVersionFile}.',
    );

    return ExitCode.success.code;
  }
}
