import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/sync_commands/_sync_devtools.dart';
import 'package:flutter_compile/src/commands/sync_commands/_sync_engine.dart';
import 'package:flutter_compile/src/commands/sync_commands/_sync_flutter.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template sync_command}
///
/// `flutter_compile sync`
/// `flutter_compile sync flutter`
/// `flutter_compile sync engine`
/// `flutter_compile sync devtools`
///
/// A [Command] to sync contributor environments with upstream.
///
/// {@endtemplate}
class SyncCommand extends Command<int> {
  /// {@macro sync_command}
  SyncCommand(this._logger) {
    addSubcommand(SyncFlutterSubCommand(_logger));
    addSubcommand(SyncEngineSubCommand(_logger));
    addSubcommand(SyncDevtoolsSubCommand(_logger));
  }

  @override
  final String name = 'sync';
  @override
  final String description =
      'Sync contributor environments [flutter|engine|devtools] with upstream.';
  @override
  final List<String> aliases = ['sy'];

  final Logger _logger;

  @override
  Future<int> run() async {
    _logger.info('Syncing all environments...\n');

    final results = <String, bool>{};

    for (final entry in [
      ('flutter', SyncFlutterSubCommand(_logger)),
      ('engine', SyncEngineSubCommand(_logger)),
      ('devtools', SyncDevtoolsSubCommand(_logger)),
    ]) {
      try {
        await entry.$2.run();
        results[entry.$1] = true;
      } on FlutterCompileException {
        results[entry.$1] = false;
      }
      _logger.info('');
    }

    final succeeded = results.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toList();
    final failed = results.entries
        .where((e) => !e.value)
        .map((e) => e.key)
        .toList();

    if (succeeded.isNotEmpty) {
      _logger.success('Synced: ${succeeded.join(', ')}');
    }
    if (failed.isNotEmpty) {
      _logger.err('Failed: ${failed.join(', ')}');
    }

    return failed.isEmpty ? ExitCode.success.code : ExitCode.software.code;
  }
}
