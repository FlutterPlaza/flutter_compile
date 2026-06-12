import 'dart:io';
import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template uninstall_command}
///
/// `flutter_compile uninstall flutter`
/// `flutter_compile uninstall devtools`
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
    argParser.addFlag('devtools',
        abbr: 'd', help: 'Uninstall DevTools environment');
  }
  final Logger _logger;

  @override
  final String name = 'devtools';
  @override
  final List<String> aliases = ['devtool'];
  @override
  final String description = 'Uninstall the DevTools development environment';

  @override
  Future<int> run() async {
    await uninstallDevToolsEnvironment(_logger);
    return ExitCode.success.code;
  }
}

class EngineUninstallSubCommand extends Command<int> {
  EngineUninstallSubCommand(this._logger);
  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description =
      'Uninstall the Flutter engine development environment';

  @override
  Future<int> run() async {
    await uninstallEngineEnvironment(_logger);
    return ExitCode.success.code;
  }
}

/// Regex that matches the flutter_compile setup CLI PATH block
/// regardless of the actual path content between the marker comments.
final _flutterCompileBlockPattern = RegExp(
  r'\n?# >>> Added by flutter_compile setup CLI >>>'
  r'[\s\S]*?'
  r'# <<< Added by flutter_compile setup CLI <<<\n?',
);

/// Regex that matches the depot_tools PATH block.
final _depotToolsBlockPattern = RegExp(
  r'\n?# >>> Added by flutter_compile setup CLI \(depot_tools\) >>>'
  r'[\s\S]*?'
  r'# <<< Added by flutter_compile setup CLI \(depot_tools\) <<<\n?',
);

Future<void> uninstallFlutterEnvironment(Logger l) async {
  l.info('Uninstalling Flutter Framework Development Environment'.blue);

  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');

  // Read flutter path from config, fall back to default
  var flutterPath = await F.readValueForKeyFromRcConfig(
    rcConfigFile,
    RunCommandKey.flutterCompile.key,
  );
  flutterPath ??= '$home${Constants.flutterCompileBin}';

  // Delete the Flutter installation directory
  final flutterDir = Directory(flutterPath);
  if (await flutterDir.exists()) {
    await flutterDir.delete(recursive: true);
    l.info('Deleted Flutter directory at $flutterPath.'.green);
  } else {
    l.warn('Flutter directory not found at $flutterPath.'.yellow);
  }

  // Remove the Flutter PATH export from env file
  final envPath = F.getEnvFilePath();
  final envFile = File(envPath);
  if (await envFile.exists()) {
    var contents = await envFile.readAsString();
    if (_flutterCompileBlockPattern.hasMatch(contents)) {
      contents = contents.replaceAll(_flutterCompileBlockPattern, '');
      await envFile.writeAsString(contents);
      l.info('Removed Flutter PATH export from .${Constants.envFile}.'.green);
    }
  }

  // Migration: also strip legacy block from shell RC
  final configPath = F.getShellConfigPath();
  final configFile = File(configPath);
  if (await configFile.exists()) {
    var contents = await configFile.readAsString();
    if (_flutterCompileBlockPattern.hasMatch(contents)) {
      contents = contents.replaceAll(_flutterCompileBlockPattern, '');
      await configFile.writeAsString(contents);
    }
  }

  // Remove the flutter_path key from .flutter_compilerc
  if (await rcConfigFile.exists()) {
    final lines = await rcConfigFile.readAsLines();
    final filtered = lines
        .where(
          (line) => !line.startsWith('${RunCommandKey.flutterCompile.key}:'),
        )
        .toList();
    await rcConfigFile.writeAsString('${filtered.join('\n')}\n');
    l.info('Removed flutter_path from .flutter_compilerc.'.green);
  }

  l.info('Flutter environment uninstalled successfully.'.green);
}

Future<void> uninstallDevToolsEnvironment(Logger l) async {
  l.info('Uninstalling DevTools Development Environment'.blue);

  final home = F.homeDir();
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

  // Remove the DevTools PATH export from env file
  final envPath = F.getEnvFilePath();
  final envFile = File(envPath);
  if (await envFile.exists()) {
    var envContents = await envFile.readAsString();
    final devtoolsExport = Constants.platformDevToolsPATHExport
        .replaceAll('{{path}}', devtoolsPath);
    if (envContents.contains(devtoolsExport)) {
      envContents = envContents.replaceAll(devtoolsExport, '');
      await envFile.writeAsString(envContents);
      l.info('Removed DevTools PATH export from .${Constants.envFile}.'.green);
    }
  }

  // Migration: also strip legacy block from shell RC
  final configPath = F.getShellConfigPath();
  final configFile = File(configPath);
  if (await configFile.exists()) {
    var contents = await configFile.readAsString();
    final devtoolsExport = Constants.platformDevToolsPATHExport
        .replaceAll('{{path}}', devtoolsPath);
    if (contents.contains(devtoolsExport)) {
      contents = contents.replaceAll(devtoolsExport, '');
      await configFile.writeAsString(contents);
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

Future<void> uninstallEngineEnvironment(Logger l) async {
  l.info('Uninstalling Flutter Engine Development Environment'.blue);

  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');

  // Read engine path from config, fall back to default
  var enginePath = await F.readValueForKeyFromRcConfig(
    rcConfigFile,
    RunCommandKey.engine.key,
  );
  enginePath ??= '$home${Constants.engineInstallPath}';

  // Delete the engine workspace directory
  final engineDir = Directory(enginePath);
  if (await engineDir.exists()) {
    await engineDir.delete(recursive: true);
    l.info('Deleted engine directory at $enginePath.'.green);
  } else {
    l.warn('Engine directory not found at $enginePath.'.yellow);
  }

  // Prompt: also remove depot_tools?
  final removeDepotTools = await F.promptUser(
    'Also remove depot_tools? (y/n) [Default: n]: ',
    defaultValue: 'n',
  );

  if (removeDepotTools.toLowerCase() == 'y') {
    var depotToolsPath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.depotTools.key,
    );
    depotToolsPath ??= '$home${Constants.depotToolsInstallPath}';

    final depotToolsDir = Directory(depotToolsPath);
    if (await depotToolsDir.exists()) {
      await depotToolsDir.delete(recursive: true);
      l.info('Deleted depot_tools directory at $depotToolsPath.'.green);
    }

    // Remove depot_tools PATH export from env file
    final envPath = F.getEnvFilePath();
    final envFile = File(envPath);
    if (await envFile.exists()) {
      var envContents = await envFile.readAsString();
      if (_depotToolsBlockPattern.hasMatch(envContents)) {
        envContents = envContents.replaceAll(_depotToolsBlockPattern, '');
        await envFile.writeAsString(envContents);
        l.info('Removed depot_tools PATH export from .${Constants.envFile}.'
            .green);
      }
    }

    // Migration: also strip legacy block from shell RC
    final configPath = F.getShellConfigPath();
    final configFile = File(configPath);
    if (await configFile.exists()) {
      var contents = await configFile.readAsString();
      if (_depotToolsBlockPattern.hasMatch(contents)) {
        contents = contents.replaceAll(_depotToolsBlockPattern, '');
        await configFile.writeAsString(contents);
      }
    }

    // Remove depot_tools_path key from .flutter_compilerc
    if (await rcConfigFile.exists()) {
      final lines = await rcConfigFile.readAsLines();
      final filtered = lines
          .where(
            (line) => !line.startsWith('${RunCommandKey.depotTools.key}:'),
          )
          .toList();
      await rcConfigFile.writeAsString('${filtered.join('\n')}\n');
      l.info('Removed depot_tools_path from .flutter_compilerc.'.green);
    }
  }

  // Remove engine_path key from .flutter_compilerc
  if (await rcConfigFile.exists()) {
    final lines = await rcConfigFile.readAsLines();
    final filtered = lines
        .where((line) => !line.startsWith('${RunCommandKey.engine.key}:'))
        .toList();
    await rcConfigFile.writeAsString('${filtered.join('\n')}\n');
    l.info('Removed engine_path from .flutter_compilerc.'.green);
  }

  l.info('Engine environment uninstalled successfully.'.green);
}
