import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkListSubCommand extends Command<int> {
  SdkListSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'list';
  @override
  final String description = 'List installed Flutter SDK versions.';
  @override
  final List<String> aliases = ['ls'];

  @override
  Future<int> run() async {
    return listSdks(_logger);
  }
}

Future<int> listSdks(Logger l) async {
  final home = Platform.environment['HOME'] ?? '';
  final versionsDir = Directory('$home${Constants.sdkVersionsPath}');

  if (!versionsDir.existsSync()) {
    l.info('No Flutter SDKs installed.');
    l.info(
      '\nRun "flutter_compile sdk install <version>" to install one.',
    );
    return ExitCode.success.code;
  }

  final entries = versionsDir.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (entries.isEmpty) {
    l.info('No Flutter SDKs installed.');
    l.info(
      '\nRun "flutter_compile sdk install <version>" to install one.',
    );
    return ExitCode.success.code;
  }

  l.info('Installed Flutter SDKs:\n');
  for (final dir in entries) {
    final name = dir.path.split('/').last;
    l.info('  $name    ${dir.path}');
  }

  // Show contributor environments if they exist
  final compiledFlutterDir =
      Directory('$home${Constants.flutterCompileInstallPath}');
  if (compiledFlutterDir.existsSync()) {
    l.info('\nContributor environments:');
    l.info(
      '  compiled  ${compiledFlutterDir.path}    (via install flutter)',
    );
  }

  return ExitCode.success.code;
}
