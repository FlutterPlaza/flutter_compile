import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template uninstall_command}
///
/// `flutter_compile uninstall flutter`
/// `flutter_compile uninstall devtool`
/// `flutter_compile uninstall engine`
///
/// A [Command] to uninstall various Flutter development environments.
///
/// {@endtemplate}
class UninstallCommand extends Command<int> {
  UninstallCommand(this._logger) {
    addSubcommand(FlutterUninstallSubCommand(_logger));
    addSubcommand(DevToolsUninstallSubCommand(_logger));
    addSubcommand(EngineUninstallSubCommand(_logger));
  }
  @override
  final String name = 'uninstall';
  @override
  final String description =
      'Uninstall various [Flutter|devTools|Engine] development environments';
  @override
  final List<String> aliases = ['delete', 'remove'];

  final Logger _logger;

  @override
  Future<int> run() async {
    printUsage();
    return ExitCode.usage.code;
  }
}

class FlutterUninstallSubCommand extends Command<int> {
  FlutterUninstallSubCommand(this._logger) {
    argParser.addFlag('flutter',
        abbr: 'f', help: 'Uninstall Flutter environment');
  }
  final Logger _logger;

  @override
  final String name = 'flutter';
  @override
  final String description = 'Uninstall the Flutter development environment';

  @override
  Future<int> run() async {
    await uninstallFlutterEnvironment(_logger);
    return ExitCode.success.code;
  }
}

class DevToolsUninstallSubCommand extends Command<int> {
  DevToolsUninstallSubCommand(this._logger) {
    argParser.addFlag('devtool',
        abbr: 'd', help: 'Uninstall DevTools environment');
  }
  final Logger _logger;

  @override
  final String name = 'devtool';
  @override
  final String description = 'Uninstall the DevTools development environment';

  @override
  Future<int> run() async {
    await uninstallDevToolsEnvironment(_logger);
    return ExitCode.success.code;
  }
}

class EngineUninstallSubCommand extends Command<int> {
  EngineUninstallSubCommand(this._logger) {
    argParser.addOption('platform',
        abbr: 'p',
        help: 'Specify the platform to uninstall (ios, android, tv)');
  }
  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description =
      'Uninstall the Flutter engine development environment';

  @override
  Future<int> run() async {
    final platform = argResults?['platform'] as String;
    if (platform == '' || !['ios', 'android', 'tv'].contains(platform)) {
      printUsage();
      return ExitCode.usage.code;
    }
    await uninstallEngineEnvironment(_logger, platform);
    return ExitCode.success.code;
  }
}

Future<void> uninstallFlutterEnvironment(Logger l) async {
  l.info('Uninstalling Flutter Framework Development Environment'.blue);
  final clonePath =
      '${Platform.environment['HOME']}${Constants.flutterCompileInstallPath}';
  final cloneDir = Directory(clonePath);

  if (await cloneDir.exists()) {
    await cloneDir.delete(recursive: true);
    l.info('✔ Flutter environment uninstalled successfully.'.green);
  } else {
    l.warn('Flutter environment not found.'.yellow);
  }
}

Future<void> uninstallDevToolsEnvironment(Logger l) async {
  l.info('Uninstalling DevTools Development Environment'.blue);

  final home = Platform.environment['HOME'] ?? '';
  final rcConfigFile = File('$home/.flutter_compilerc');

  // Read devtools path from config, fall back to default
  var devtoolsPath = await F.readValueForKeyFromRcConfig(
      rcConfigFile, RunCommandKey.devTools.key);
  devtoolsPath ??= '$home${Constants.devToolsInstallPath}';

  // Delete the directory if it exists
  final devtoolsDir = Directory(devtoolsPath);
  if (await devtoolsDir.exists()) {
    await devtoolsDir.delete(recursive: true);
    l.info('Deleted DevTools directory at $devtoolsPath.'.green);
  } else {
    l.warn('DevTools directory not found at $devtoolsPath.'.yellow);
  }

  // Remove the DevTools PATH export from shell config
  final shell = Platform.environment['SHELL'] ?? '';
  final shellConfig = shell.contains('bash')
      ? '.bashrc'
      : shell.contains('zsh')
          ? '.zshrc'
          : '.profile';
  final configPath = '$home/$shellConfig';
  final configFile = File(configPath);
  if (await configFile.exists()) {
    var contents = await configFile.readAsString();
    final devtoolsExport =
        Constants.devToolsPATHExport.replaceAll('{{path}}', devtoolsPath);
    if (contents.contains(devtoolsExport)) {
      contents = contents.replaceAll(devtoolsExport, '');
      await configFile.writeAsString(contents);
      l.info('Removed DevTools PATH export from $shellConfig.'.green);
    }
  }

  // Remove the devtools_path key from .flutter_compilerc
  if (await rcConfigFile.exists()) {
    final lines = await rcConfigFile.readAsLines();
    final filtered = lines
        .where((line) => !line.startsWith('${RunCommandKey.devTools.key}:'))
        .toList();
    await rcConfigFile.writeAsString('${filtered.join('\n')}\n');
    l.info('Removed devtools_path from .flutter_compilerc.'.green);
  }

  l.info('DevTools environment uninstalled successfully.'.green);
}

Future<void> uninstallEngineEnvironment(Logger l, String platform) async {
  l.info(
    'Uninstalling Flutter Engine Development Environment for $platform'.blue,
  );
  // Add the logic to uninstall the Flutter engine environment for the specified platform here
}
