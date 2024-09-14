import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
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
  @override
  final String name = 'uninstall';
  @override
  final String description =
      'Uninstall various [Flutter|devTools|Engine] development environments';
  @override
  final List<String> aliases = ['delete', 'remove'];

  final Logger _logger;

  UninstallCommand(this._logger) {
    addSubcommand(FlutterUninstallSubCommand(_logger));
    addSubcommand(DevToolsUninstallSubCommand(_logger));
    addSubcommand(EngineUninstallSubCommand(_logger));
  }

  @override
  Future<int> run() async {
    printUsage();
    return ExitCode.usage.code;
  }
}

class FlutterUninstallSubCommand extends Command<int> {
  final Logger _logger;

  FlutterUninstallSubCommand(this._logger) {
    argParser.addFlag('flutter',
        abbr: 'f', help: 'Uninstall Flutter environment');
  }

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
  final Logger _logger;

  DevToolsUninstallSubCommand(this._logger) {
    argParser.addFlag('devtool',
        abbr: 'd', help: 'Uninstall DevTools environment');
  }

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
  final Logger _logger;

  EngineUninstallSubCommand(this._logger) {
    argParser.addOption('platform',
        abbr: 'p',
        help: 'Specify the platform to uninstall (ios, android, tv)');
  }

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
  final String clonePath =
      '${Platform.environment['HOME']}${Constants.flutterCompileInstallPath}';
  final Directory cloneDir = Directory(clonePath);

  if (await cloneDir.exists()) {
    await cloneDir.delete(recursive: true);
    l.info('✔ Flutter environment uninstalled successfully.'.green);
  } else {
    l.warn('Flutter environment not found.'.yellow);
  }
}

Future<void> uninstallDevToolsEnvironment(Logger l) async {
  l.info('Uninstalling DevTools Development Environment'.blue);
  // Add the logic to uninstall the DevTools environment here
}

Future<void> uninstallEngineEnvironment(Logger l, String platform) async {
  l.info(
      'Uninstalling Flutter Engine Development Environment for $platform'.blue);
  // Add the logic to uninstall the Flutter engine environment for the specified platform here
}
