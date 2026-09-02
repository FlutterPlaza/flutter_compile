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

/// The reserved key under which machine-readable config output carries
/// [ProjectScopedKeyAdvisory] entries, mapped by config key.
///
/// Leading underscore because the payload is otherwise a flat map of
/// real config keys: a consumer that renders rows can skip anything
/// starting with `_` and stay correct, and no `key:value` line an rc
/// file would sensibly contain collides with it.
const String kConfigAdvisoriesKey = '_advisories';

/// A config key that `config` reads and writes MACHINE-WIDE while the
/// code push commands resolve it PER PROJECT, reported together with
/// what the current project actually resolves.
///
/// Structured rather than a bare string because the same fact has to
/// reach three audiences: a human reading `fcp config get`, a script
/// reading `fcp config list --json`, and an IDE reading the daemon's
/// `config.get` / `config.set` / `config.list`. The last two need the
/// pieces, not a sentence.
class ProjectScopedKeyAdvisory {
  const ProjectScopedKeyAdvisory({
    required this.key,
    required this.projectFile,
    required this.projectValue,
  });

  /// The config key being shadowed (today only `codepush_app_id`).
  final String key;

  /// Absolute path of the project-local `.flutter_compilerc` that wins.
  final String projectFile;

  /// The value that file sets — what the code push commands resolve.
  final String projectValue;

  /// The human-facing sentence. Single source so the CLI and any IDE
  /// that chooses to show text rather than build its own cannot drift.
  String get message => 'This project overrides $key in $projectFile '
      '(currently $projectValue), and that value is the one the code '
      'push commands use here. Edit that file — or pass --app-id — to '
      'change what this project resolves.';

  Map<String, dynamic> toJson() => {
        'key': key,
        'project_file': projectFile,
        'project_value': projectValue,
        'message': message,
      };
}

/// The advisory for [key] when the current project shadows it, or null
/// when there is nothing to say.
///
/// `config` is documented as a view onto `~/.flutter_compilerc`, and it
/// stays that: redirecting one key to a different file would be a
/// worse surprise. But without this, `config get codepush_app_id`
/// reports a value the next `fcp codepush patch` will not use, and
/// `config set` looks like it took effect when the project file still
/// wins. Async only because reading the project file is.
Future<ProjectScopedKeyAdvisory?> projectScopedKeyAdvisoryFor(
  String key, {
  Directory? projectDir,
}) async {
  if (key != Constants.codePushAppIdKey) return null;
  final projectRc = CodePushClient.projectRcFile(from: projectDir);
  if (projectRc == null) return null;
  final local = await F.readValueForKeyFromRcConfig(projectRc, key);
  if (local == null || local.trim().isEmpty) return null;
  return ProjectScopedKeyAdvisory(
    key: key,
    projectFile: projectRc.path,
    // Trimmed to match what `getAppId` actually resolves. Echoing the
    // raw slice would print a padded id as if it were the value in
    // use, which is the one thing this advisory exists to prevent.
    projectValue: local.trim(),
  );
}

/// [projectScopedKeyAdvisoryFor] as the human-facing sentence alone.
Future<String?> projectScopedKeyAdvisory(
  String key, {
  Directory? projectDir,
}) async =>
    (await projectScopedKeyAdvisoryFor(key, projectDir: projectDir))?.message;

/// The machine-readable `config list` payload: every machine-wide
/// setting, plus [kConfigAdvisoriesKey] naming the keys this project
/// resolves differently.
///
/// Shared by `fcp config list --json` and the daemon's `config.list`
/// so the CLI and the IDE report the same thing — the advisory used to
/// exist only on the human CLI path, which is the one surface that
/// least needed it.
Future<Map<String, dynamic>> configListPayload({Directory? projectDir}) async {
  final config = await gatherConfig();
  final advisory = await projectScopedKeyAdvisoryFor(
    Constants.codePushAppIdKey,
    projectDir: projectDir,
  );
  return <String, dynamic>{
    ...config,
    if (advisory != null)
      kConfigAdvisoriesKey: {advisory.key: advisory.toJson()},
  };
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

    // JSON first and unconditionally: an empty machine-wide file is
    // exactly the case where a project override is the only thing
    // configured, so the advisory must survive the empty branch.
    if (asJson) {
      _logger.info(json.encode(await configListPayload()));
      return ExitCode.success.code;
    }

    final config = await gatherConfig();
    if (config.isEmpty) {
      final home = F.homeDir();
      final rcConfigFile = File('$home/.flutter_compilerc');
      if (!await rcConfigFile.exists()) {
        _logger.info('No .flutter_compilerc file found.');
      } else {
        _logger.info('.flutter_compilerc is empty.');
      }
    } else {
      for (final entry in config.entries) {
        _logger.info('${entry.key}:${entry.value}');
      }
    }

    // Listing the machine-wide values without this is the same trap
    // `config get` had: the operator reads a codepush_app_id the next
    // `fcp codepush patch` will not use.
    final advisory = await projectScopedKeyAdvisoryFor(
      Constants.codePushAppIdKey,
    );
    if (advisory != null) _logger.warn(advisory.message);

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
    final advisory = await projectScopedKeyAdvisoryFor(key);

    // "Key not found" beside "…(currently project-a-app)" reads as a
    // contradiction. When the project resolves the key, the advisory
    // IS the answer, so the machine-wide miss is not worth a line.
    if (value != null) {
      _logger.info('$key:$value');
    } else if (advisory == null) {
      _logger.info('Key not found: $key');
    }
    if (advisory != null) _logger.warn(advisory.message);

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
    final advisory = await projectScopedKeyAdvisoryFor(key);
    if (advisory != null) _logger.warn(advisory.message);

    return ExitCode.success.code;
  }
}
