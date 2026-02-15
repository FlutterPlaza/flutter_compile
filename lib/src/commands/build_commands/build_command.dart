import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/build_commands/_engine_build.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template build_command}
///
/// `flutter_compile build engine`
///
/// A [Command] to build various Flutter development artifacts.
///
/// {@endtemplate}
class BuildCommand extends Command<int> {
  BuildCommand(this._logger) {
    addSubcommand(EngineBuildSubCommand(_logger));
  }
  @override
  final String name = 'build';
  @override
  final String description = 'Build various [engine] development artifacts.';
  @override
  final List<String> aliases = ['b'];

  final Logger _logger;

  @override
  Future<int> run() async {
    printUsage();
    return ExitCode.usage.code;
  }
}
