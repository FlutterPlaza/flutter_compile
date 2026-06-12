import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class DevToolsSubCommand extends Command<int> {
  DevToolsSubCommand(this._logger) {
    argParser.addFlag(
      'devtools',
      abbr: 'd',
      help: 'Install DevTools environment',
    );
  }
  final Logger _logger;

  @override
  final String name = 'devtools';
  @override
  final String description = 'Set up the DevTools development environment';

  @override
  Future<int> run() async {
    return setupDevToolsEnvironment(_logger);
  }
}

Future<int> setupDevToolsEnvironment(Logger l) async {
  l.info('DevTools Development Environment Setup'.blue);

  // Check if Flutter and Dart are in PATH and verify the correct versions
  if (!await F.isCommandAvailable('flutter') ||
      !await F.isCommandAvailable('dart')) {
    l.err(
      'Error: flutter and dart must be in your PATH. Please ensure Flutter SDK is correctly installed and added to PATH.',
    );
    return ExitCode.unavailable.code;
  }

  // Clone the DevTools repo
  var githubUsername = await F.getGitHubName();

  var cloneMethod = await F.promptUser(
    'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
    defaultValue: '1',
  );
  var cloneUrl = cloneMethod == '2'
      ? 'https://github.com/flutter/devtools.git'
      : 'git@github.com:flutter/devtools.git';
  final clonePath = '${F.homeDir()}${Constants.devToolsInstallPath}';
  final cloneDir = await F.promptUser(
    'Enter the directory to clone the DevTools repository [Default: $clonePath]: ',
    defaultValue: clonePath,
  );

  await F.cloneRepository(cloneUrl, cloneDir);
  Directory.current = cloneDir;

  // Set up git remotes (idempotent — safe to re-run)
  final upstreamUrl = 'https://github.com/flutter/devtools.git';
  final forkUrl = cloneMethod == '2'
      ? 'https://github.com/$githubUsername/devtools.git'
      : 'git@github.com:$githubUsername/devtools.git';
  await _ensureRemote(l, 'upstream', upstreamUrl, cloneDir);
  await _ensureRemote(l, 'origin', forkUrl, cloneDir);

  // Fetch upstream and set tracking branch
  l.info('Fetching upstream...');
  await F.runCommand('git', ['fetch', 'upstream'], workingDirectory: cloneDir);
  try {
    await F.runCommand(
        'git', ['branch', '--set-upstream-to=upstream/master', 'master'],
        workingDirectory: cloneDir);
  } catch (_) {
    // May fail if already set or branch name differs — non-fatal
    l.warn('Could not set upstream tracking branch (may already be set).');
  }

  // Ensure the DevTools 'tool' directory exists
  var toolDir = Directory('$cloneDir/tool');
  if (!await toolDir.exists()) {
    l.err('Error: devtools/tool directory not found.');
    return ExitCode.unavailable.code;
  }

  // Run Flutter pub get for the tool directory
  await F.runCommand(
    'flutter',
    ['pub', 'get', '--directory', toolDir.path],
  );

  // Save devtools path to .flutter_compilerc
  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');
  await F.writeKeyValueToRcConfig(
    rcConfigFile,
    RunCommandKey.devTools.key,
    cloneDir,
  );

  // Add the DevTools tool bin to the env file (and ensure source line in shell RC)
  await F.ensureSourceLineInShellRc();
  final envPath = F.getEnvFilePath();
  final envFile = File(envPath);

  var envContents = '';
  if (await envFile.exists()) {
    envContents = await envFile.readAsString();
  }

  final devtoolsToolBinPath =
      Constants.platformDevToolsPATHExport.replaceAll('{{path}}', cloneDir);
  if (!envContents.contains(devtoolsToolBinPath.trim())) {
    envContents += devtoolsToolBinPath;
    await envFile.parent.create(recursive: true);
    await envFile.writeAsString(envContents);
    l.info('Added DevTools tool/bin to PATH in .${Constants.envFile}.'.green);
  }

  // Optional step: Check and update the DevTools Flutter SDK
  try {
    await F.runCommand(
        'devtools_tool', ['update-flutter-sdk', '--update-on-path']);
  } catch (e) {
    l.warn(
        'devtools_tool update-flutter-sdk failed (may need terminal restart): $e');
  }

  // Inform the user to restart their terminal
  l
    ..info(
        '\nSetup complete! Please restart your terminal or source your shell configuration to apply PATH changes.\n'
            .green)
    ..info('To verify the setup, run the following command:')
    ..info(
        '`flutter run` on a sample Flutter project and connect it to DevTools.');
  await displayIncrementalInfo();

  return ExitCode.success.code;
}

/// Ensure a git remote exists with the given URL.
/// If it already exists, update its URL. If not, add it.
Future<void> _ensureRemote(
    Logger l, String name, String url, String workingDirectory) async {
  final result = await Process.run(
    'git',
    ['remote', 'get-url', name],
    workingDirectory: workingDirectory,
  );
  if (result.exitCode == 0) {
    // Remote exists — update URL if different
    final currentUrl = (result.stdout as String).trim();
    if (currentUrl != url) {
      await F.runCommand('git', ['remote', 'set-url', name, url],
          workingDirectory: workingDirectory);
      l.info('Updated remote "$name" to $url'.green);
    } else {
      l.info('Remote "$name" already set to $url'.green);
    }
  } else {
    // Remote doesn't exist — add it
    await F.runCommand('git', ['remote', 'add', name, url],
        workingDirectory: workingDirectory);
    l.info('Added remote "$name" → $url'.green);
  }
}

Future<void> displayIncrementalInfo() async {
  final length = Constants.infoSections.length;
  for (var i = 0; i < length; i++) {
    final section = Constants.infoSections[i];
    stdout
      ..writeln(section)
      ..writeln('[${i + 1}/$length]Press Enter to continue...'.blue);
    stdin.readLineSync();
  }
}
