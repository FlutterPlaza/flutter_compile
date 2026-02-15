import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/install_commands/_devtools.dart';
import 'package:flutter_compile/src/commands/install_commands/_engine.dart';
import 'package:flutter_compile/src/commands/install_commands/_flutter.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template flutter_install_command}
///
/// `flutter_compile install flutter`
/// `flutter_compile install devTools`
/// `flutter_compile install engine [ios|android|tv]`
///
/// A [Command] to set up various Flutter development environments.
///
/// {@endtemplate}
class InstallCommand extends Command<int> {
  InstallCommand(this._logger) {
    addSubcommand(FlutterSubCommand(_logger));
    addSubcommand(DevToolsSubCommand(_logger));
    addSubcommand(EngineSubCommand(_logger));
  }
  @override
  final String name = 'install';
  @override
  final String description =
      'Set up various [flutter|devtools|engine] development environments.';
  @override
  final List<String> aliases = ['i'];

  final Logger _logger;

  @override
  Future<int> run() async {
    printUsage();
    return ExitCode.usage.code;
  }
}
