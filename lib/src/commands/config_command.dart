import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class ConfigCommand extends Command<int> {
  ConfigCommand(this._logger) {
    addSubcommand(_ConfigListSubCommand(_logger));
    addSubcommand(_ConfigGetSubCommand(_logger));
    addSubcommand(_ConfigSetSubCommand(_logger));
  }

  final Logger _logger;

  @override
  final String name = 'config';

  @override
  final List<String> aliases = ['cf'];

  @override
  final String description = 'View and modify ~/.flutter_compilerc settings.';

  @override
  Future<int> run() async {
    // Default to list when no subcommand given
    return _ConfigListSubCommand(_logger).run();
  }
}

/// Normalize friendly key names to their raw config keys.
String _normalizeKey(String key) {
  const keyMap = {
    'flutter': 'flutter_path',
    'engine': 'engine_path',
    'devtools': 'devtools_path',
    'depot_tools': 'depot_tools_path',
  };
  return keyMap[key] ?? key;
}

class _ConfigListSubCommand extends Command<int> {
  _ConfigListSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'list';

  @override
  final String description = 'List all configuration values.';

  @override
  Future<int> run() async {
    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');

    if (!await rcConfigFile.exists()) {
      _logger.info('No .flutter_compilerc file found.');
      return ExitCode.success.code;
    }

    final lines = await rcConfigFile.readAsLines();
    final entries = lines.where((line) => line.contains(':')).toList();

    if (entries.isEmpty) {
      _logger.info('.flutter_compilerc is empty.');
      return ExitCode.success.code;
    }

    for (final entry in entries) {
      _logger.info(entry);
    }

    return ExitCode.success.code;
  }
}

class _ConfigGetSubCommand extends Command<int> {
  _ConfigGetSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'get';

  @override
  final String description = 'Get a configuration value. '
      'Usage: config get <key>';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.isEmpty) {
      _logger.err('Usage: flutter_compile config get <key>');
      return ExitCode.usage.code;
    }

    final key = _normalizeKey(rest.first);
    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');
    final value = await F.readValueForKeyFromRcConfig(rcConfigFile, key);

    if (value == null) {
      _logger.info('Key not found: $key');
    } else {
      _logger.info('$key:$value');
    }

    return ExitCode.success.code;
  }
}

class _ConfigSetSubCommand extends Command<int> {
  _ConfigSetSubCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'set';

  @override
  final String description = 'Set a configuration value. '
      'Usage: config set <key> <value>';

  @override
  Future<int> run() async {
    final rest = argResults?.rest ?? [];
    if (rest.length < 2) {
      _logger.err('Usage: flutter_compile config set <key> <value>');
      return ExitCode.usage.code;
    }

    final key = _normalizeKey(rest[0]);
    final value = rest[1];
    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');

    await F.writeKeyValueToRcConfig(rcConfigFile, key, value);
    _logger.info('Set $key:$value');

    return ExitCode.success.code;
  }
}
