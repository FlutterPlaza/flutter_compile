import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_exec.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_global.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_install.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_list.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_remove.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_use.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template sdk_command}
///
/// `flutter_compile sdk`
/// `flutter_compile sdk install <version|channel>`
/// `flutter_compile sdk list`
/// `flutter_compile sdk remove <version>`
/// `flutter_compile sdk global [version]`
/// `flutter_compile sdk use [version]`
/// `flutter_compile sdk exec <command> [args...]`
///
/// A [Command] to manage multiple Flutter SDK versions.
///
/// {@endtemplate}
class SdkCommand extends Command<int> {
  /// {@macro sdk_command}
  SdkCommand(this._logger) {
    addSubcommand(SdkInstallSubCommand(_logger));
    addSubcommand(SdkListSubCommand(_logger));
    addSubcommand(SdkRemoveSubCommand(_logger));
    addSubcommand(SdkGlobalSubCommand(_logger));
    addSubcommand(SdkUseSubCommand(_logger));
    addSubcommand(SdkExecSubCommand(_logger));
  }

  @override
  final String name = 'sdk';
  @override
  final String description = 'Manage Flutter SDK versions.';

  final Logger _logger;

  @override
  Future<int> run() async {
    // Default to list when no subcommand given
    return SdkListSubCommand(_logger).run();
  }
}
