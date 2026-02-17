import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class EngineSubCommand extends Command<int> {
  EngineSubCommand(this._logger) {
    argParser.addOption(
      'platform',
      abbr: 'p',
      help: 'Specify the target platform',
      allowed: ['android', 'ios', 'macos', 'linux', 'web', 'host'],
      defaultsTo: 'host',
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
    return setupEngineEnvironment(_logger, platform);
  }
}

Future<int> setupEngineEnvironment(Logger l, String platform) async {
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

  // Install depot_tools
  final depotToolsPath = await _ensureDepotTools(l);

  // Get GitHub username and clone method
  final githubUsername = await F.getGitHubName();
  final cloneMethod = await F.promptUser(
    'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
    defaultValue: '1',
  );

  final home = F.homeDir();
  final enginePath = '$home${Constants.engineInstallPath}';
  final engineDir = await F.promptUser(
    'Enter the directory for the engine workspace [Default: $enginePath]: ',
    defaultValue: enginePath,
  );

  // Create engine workspace directory
  final dir = Directory(engineDir);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
    l.info('Created engine workspace at $engineDir');
  }

  // Generate .gclient file
  final forkUrl = cloneMethod == '2'
      ? 'https://github.com/$githubUsername/engine.git'
      : 'git@github.com:$githubUsername/engine.git';
  final gclientContent =
      Constants.gclientFileTemplate.replaceAll('{{engine_url}}', forkUrl);
  await F.writeFile('$engineDir/.gclient', gclientContent);
  l.info('Generated .gclient file.'.green);

  // Run gclient sync (use full path since depot_tools may not be in PATH yet)
  l.info('\nRunning gclient sync (this may take 20-40 minutes)...\n'.yellow);
  await F.runCommand(
    '$depotToolsPath/gclient',
    ['sync'],
    workingDirectory: engineDir,
  );
  l.info('gclient sync completed.'.green);

  // Configure git remotes on $engineDir/src/flutter
  final flutterEngineDir = '$engineDir/src/flutter';
  final upstreamUrl = cloneMethod == '2'
      ? Constants.engineUpstreamHTTPS
      : Constants.engineUpstreamSSH;

  // Set upstream remote
  try {
    await F.runCommand(
      'git',
      ['remote', 'add', 'upstream', upstreamUrl],
      workingDirectory: flutterEngineDir,
    );
  } catch (_) {
    // upstream may already exist from gclient sync
  }
  l.info('Configured git remotes on src/flutter.'.green);

  // Save engine path to .flutter_compilerc
  final rcConfigFile = File('$home/.flutter_compilerc');
  await F.writeKeyValueToRcConfig(
    rcConfigFile,
    RunCommandKey.engine.key,
    engineDir,
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

  // Add depot_tools to shell PATH config
  final configPath = F.getShellConfigPath();
  final configFile = File(configPath);

  if (await configFile.exists()) {
    var contents = await configFile.readAsString();
    final depotToolsExport = Constants.platformDepotToolsPATHExport
        .replaceAll('{{path}}', depotToolsPath);
    if (!contents.contains(depotToolsExport)) {
      contents += depotToolsExport;
      await configFile.writeAsString(contents);
      l.info(
          'Added depot_tools to PATH in ${configPath.split(Platform.isWindows ? r'\' : '/').last}.'
              .green);
    }
  }

  return depotToolsPath;
}
