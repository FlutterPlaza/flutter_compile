import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

Future<Map<String, String>> gatherConfig() async {
  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');

  if (!await rcConfigFile.exists()) {
    return <String, String>{};
  }

  final lines = await rcConfigFile.readAsLines();
  final entries = lines.where((line) => line.contains(':')).toList();
  final map = <String, String>{};
  for (final entry in entries) {
    final parts = entry.split(':');
    if (parts.length == 2) {
      map[parts[0]] = parts[1];
    }
  }
  return map;
}

/// Normalize friendly key names to their raw config keys.
String normalizeConfigKey(String key) {
  const keyMap = {
    'flutter': 'flutter_path',
    'engine': 'engine_path',
    'devtools': 'devtools_path',
    'depot_tools': 'depot_tools_path',
    'global_sdk': 'global_sdk_version',
  };
  return keyMap[key] ?? key;
}

/// The advisory for a key that this command reads and writes
/// machine-wide but the code push commands resolve PER PROJECT, when
/// the current project already sets it locally — or null when there is
/// nothing to say.
///
/// `config` is documented as a view onto `~/.flutter_compilerc`, and it
/// stays that: redirecting one key to a different file would be a
/// worse surprise. But without this line, `config get codepush_app_id`
/// reports a value the next `fcp codepush patch` will not use, and
/// `config set` looks like it took effect when the project file still
/// wins. Async only because reading the project file is.
Future<String?> projectScopedKeyAdvisory(
  String key, {
  Directory? projectDir,
}) async {
  if (key != Constants.codePushAppIdKey) return null;
  final projectRc = CodePushClient.projectRcFile(from: projectDir);
  if (projectRc == null) return null;
  final local = await F.readValueForKeyFromRcConfig(projectRc, key);
  if (local == null || local.trim().isEmpty) return null;
  return 'This project overrides $key in ${projectRc.path} '
      '(currently $local), and that value is the one the code push '
      'commands use here. Edit that file — or pass --app-id — to change '
      'what this project resolves.';
}

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

class _ConfigListSubCommand extends Command<int> {
  _ConfigListSubCommand(this._logger) {
    argParser.addFlag(
      'json',
      help: 'Output as JSON.',
      negatable: false,
    );
  }

  final Logger _logger;

  @override
  final String name = 'list';

  @override
  final String description = 'List all configuration values.';

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;
    final config = await gatherConfig();

    if (config.isEmpty) {
      final home = F.homeDir();
      final rcConfigFile = File('$home/.flutter_compilerc');
      if (asJson) {
        _logger.info(json.encode(<String, String>{}));
      } else if (!await rcConfigFile.exists()) {
        _logger.info('No .flutter_compilerc file found.');
      } else {
        _logger.info('.flutter_compilerc is empty.');
      }
      return ExitCode.success.code;
    }

    if (asJson) {
      _logger.info(json.encode(config));
      return ExitCode.success.code;
    }

    for (final entry in config.entries) {
      _logger.info('${entry.key}:${entry.value}');
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

    final key = normalizeConfigKey(rest.first);
    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');
    final value = await F.readValueForKeyFromRcConfig(rcConfigFile, key);

    if (value == null) {
      _logger.info('Key not found: $key');
    } else {
      _logger.info('$key:$value');
    }
    final advisory = await projectScopedKeyAdvisory(key);
    if (advisory != null) _logger.warn(advisory);

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

    final key = normalizeConfigKey(rest[0]);
    final value = rest[1];
    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');

    await F.writeKeyValueToRcConfig(rcConfigFile, key, value);
    _logger.info('Set $key:$value');
    final advisory = await projectScopedKeyAdvisory(key);
    if (advisory != null) _logger.warn(advisory);

    return ExitCode.success.code;
  }
}
