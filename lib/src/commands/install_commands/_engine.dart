import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class EngineSubCommand extends Command<int> {
  EngineSubCommand(this._logger) {
    argParser
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Specify the target platform',
        allowed: ['android', 'ios', 'macos', 'linux', 'web', 'host'],
        defaultsTo: 'host',
      )
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Force gclient sync with --reset --force (resolves dirty repos)',
        defaultsTo: false,
      );
  }
  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description =
      'Set up the Flutter engine development environment';

  @override
  Future<int> run() async {
    final platform = argResults?['platform'] as String;
    final force = argResults?['force'] as bool;
    return setupEngineEnvironment(_logger, platform, force: force);
  }
}

Future<int> setupEngineEnvironment(
  Logger l,
  String platform, {
  bool force = false,
}) async {
  l.info('Flutter Engine Development Environment Setup for $platform'.blue);

  final os = Platform.operatingSystem;
  if (os != 'linux' && os != 'macos' && os != 'windows') {
    l.err('This tool supports only Linux, macOS, and Windows platforms.');
    return ExitCode.usage.code;
  }

  // Check prerequisites
  l.info('\nChecking prerequisites...');
  if (!await F.isCommandAvailable('git')) {
    l.err('Error: git is not installed. Please install Git and try again.');
    return ExitCode.unavailable.code;
  }
  l.success('Git is installed.'.green);

  if (!await F.isCommandAvailable('python3')) {
    l.err(
      'Error: Python3 is not installed. Please install Python and try again.',
    );
    return ExitCode.unavailable.code;
  }
  l.success('Python3 is installed.'.green);

  // Resolve the Flutter contributor directory (engine lives inside it)
  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');

  var flutterBinPath = await F.readValueForKeyFromRcConfig(
    rcConfigFile,
    RunCommandKey.flutterCompile.key,
  );
  final defaultFlutterPath = '$home${Constants.flutterCompileInstallPath}';

  // flutter_path in rc config stores the bin dir (e.g. .../flutter/bin);
  // we need the repo root (e.g. .../flutter) for gclient and git ops.
  String toRepoRoot(String p) {
    final sep = Platform.isWindows ? r'\' : '/';
    return p.endsWith('${sep}bin') ? p.substring(0, p.length - 4) : p;
  }

  final flutterDir = (flutterBinPath != null && flutterBinPath.isNotEmpty)
      ? toRepoRoot(flutterBinPath)
      : defaultFlutterPath;

  if (!await Directory(flutterDir).exists()) {
    l.err(
      'Flutter contributor environment not found at $flutterDir.\n'
      'Run "flutter_compile install flutter" first, then re-run this command.',
    );
    return ExitCode.config.code;
  }

  // Verify it's a git repo with an origin remote
  final originResult = await Process.run('git', [
    'remote',
    'get-url',
    'origin',
  ], workingDirectory: flutterDir);
  if (originResult.exitCode != 0) {
    l.err(
      'Could not read git origin URL from $flutterDir.\n'
      'Ensure the Flutter contributor environment is set up correctly.',
    );
    return ExitCode.config.code;
  }
  final originUrl = (originResult.stdout as String).trim();
  l.info('Using Flutter checkout at $flutterDir'.green);
  l.info('Fork URL: $originUrl');

  // Install depot_tools
  final depotToolsPath = await _ensureDepotTools(l);

  // Generate .gclient file in the flutter directory
  final gclientFile = File('$flutterDir/.gclient');
  if (await gclientFile.exists()) {
    l.info('.gclient already exists, skipping generation.'.green);
  } else {
    final gclientContent = Constants.gclientFileTemplate.replaceAll(
      '{{flutter_url}}',
      originUrl,
    );
    await F.writeFile('$flutterDir/.gclient', gclientContent);
    l.info('Generated .gclient file.'.green);
  }

  // Prepend depot_tools to PATH so gclient/vpython3 are found
  final syncEnv = <String, String>{};
  final currentPath = Platform.environment['PATH'] ?? '';
  syncEnv['PATH'] =
      '$depotToolsPath${Platform.isWindows ? ';' : ':'}$currentPath';

  // Run gclient sync with automatic retry on failure
  l.info('\nRunning gclient sync (this may take 20-40 minutes)...\n'.yellow);
  final syncResult = await _runGclientSync(
    l,
    gclientPath: '$depotToolsPath/gclient',
    workingDirectory: flutterDir,
    environment: syncEnv,
    force: force,
  );
  if (syncResult != ExitCode.success.code) {
    return syncResult;
  }

  // Save engine path (flutter/engine) to .flutter_compilerc
  await F.writeKeyValueToRcConfig(
    rcConfigFile,
    RunCommandKey.engine.key,
    '$flutterDir/engine',
  );
  l.info('Saved engine path to .flutter_compilerc.'.green);

  // Save depot_tools path to .flutter_compilerc
  await F.writeKeyValueToRcConfig(
    rcConfigFile,
    RunCommandKey.depotTools.key,
    depotToolsPath,
  );

  l
    ..info('\nEngine environment setup complete!'.green)
    ..info('\nThe engine builds from the same Flutter checkout at $flutterDir')
    ..info('\nNext steps:')
    ..info('  1. Run `flutter_compile build engine -p $platform` to build')
    ..info('  2. Run `flutter_compile doctor` to verify your environment');

  return ExitCode.success.code;
}

Future<String> _ensureDepotTools(Logger l) async {
  // Check if gclient is already available in PATH
  if (await F.isCommandAvailable('gclient')) {
    l.info('depot_tools (gclient) already available in PATH.'.green);
    final lookupCommand = Platform.isWindows ? 'where' : 'which';
    final result = await Process.run(lookupCommand, ['gclient']);
    final gclientPath = (result.stdout as String).trim();
    // depot_tools dir is parent of gclient binary
    return File(gclientPath).parent.path;
  }

  final home = F.homeDir();
  final depotToolsPath = '$home${Constants.depotToolsInstallPath}';
  final depotToolsDir = Directory(depotToolsPath);

  if (!await depotToolsDir.exists()) {
    l.info('\nInstalling depot_tools...');
    await F.cloneRepository(Constants.depotToolsCloneUrl, depotToolsPath);
    l.info('depot_tools installed at $depotToolsPath.'.green);
  } else {
    l.info('depot_tools directory already exists at $depotToolsPath.'.green);
  }

  // Add depot_tools to env file (and ensure source line in shell RC)
  await F.ensureSourceLineInShellRc();
  final envPath = F.getEnvFilePath();
  final envFile = File(envPath);

  var envContents = '';
  if (await envFile.exists()) {
    envContents = await envFile.readAsString();
  }
  final depotToolsExport = Constants.platformDepotToolsPATHExport.replaceAll(
    '{{path}}',
    depotToolsPath,
  );
  if (!envContents.contains(depotToolsExport.trim())) {
    envContents += depotToolsExport;
    await envFile.parent.create(recursive: true);
    await envFile.writeAsString(envContents);
    l.info('Added depot_tools to PATH in .${Constants.envFile}.'.green);
  }

  return depotToolsPath;
}

/// Runs gclient sync with automatic retry on failure.
///
/// Strategy:
/// 1. If [force] is true, jump straight to forced sync.
/// 2. Otherwise try a normal `gclient sync` first.
/// 3. On failure, retry with `--force --reset --delete_unversioned_trees`
///    which resolves dirty repos and leftover state.
/// 4. On second failure, return an error with manual recovery instructions.
Future<int> _runGclientSync(
  Logger l, {
  required String gclientPath,
  required String workingDirectory,
  required Map<String, String> environment,
  required bool force,
}) async {
  if (!force) {
    try {
      await F.runCommand(
        gclientPath,
        ['sync'],
        workingDirectory: workingDirectory,
        environment: environment,
      );
      l.info('gclient sync completed.'.green);
      return ExitCode.success.code;
    } on Exception catch (e) {
      l.warn(
        '\ngclient sync failed: $e\n'
                'Retrying with --force --reset to resolve dirty repos...\n'
            .yellow,
      );
    }
  }

  // Forced sync: reset dirty repos and delete unversioned trees
  try {
    l.info('Running forced gclient sync...'.yellow);
    await F.runCommand(
      gclientPath,
      ['sync', '--force', '--reset', '--delete_unversioned_trees'],
      workingDirectory: workingDirectory,
      environment: environment,
    );
    l.info('gclient sync completed (forced).'.green);
    return ExitCode.success.code;
  } on Exception catch (e) {
    l.err(
      '\ngclient sync failed even with --force --reset: $e\n\n'
      'Manual recovery steps:\n'
      '  1. cd $workingDirectory\n'
      '  2. $gclientPath sync --force --reset --delete_unversioned_trees\n'
      '  3. If that fails, delete engine/src and re-run:\n'
      '     rm -rf $workingDirectory/engine/src\n'
      '     flutter_compile install engine --force\n',
    );
    return ExitCode.software.code;
  }
}
