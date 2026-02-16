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
  final clonePath =
      '${Platform.environment['HOME']}${Constants.devToolsInstallPath}';
  final cloneDir = await F.promptUser(
    'Enter the directory to clone the DevTools repository [Default: $clonePath]: ',
    defaultValue: clonePath,
  );

  await F.cloneRepository(cloneUrl, cloneDir);
  Directory.current = cloneDir;

  // Add upstream remote and set up tracking branch
  await F.runCommand('git',
      ['remote', 'add', 'upstream', 'https://github.com/flutter/devtools.git']);
  await F.runCommand('git', ['fetch', 'upstream']);
  await F.runCommand(
      'git', ['branch', '--set-upstream-to=upstream/master', 'master']);

  // Add origin remote (for the user's fork)
  final forkUrl = cloneMethod == '2'
      ? 'https://github.com/$githubUsername/devtools.git'
      : 'git@github.com:$githubUsername/devtools.git';
  await F.runCommand('git', ['remote', 'add', 'origin', forkUrl]);

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

  // Add the DevTools tool bin to the PATH
  final configPath = F.getShellConfigPath();
  final configFile = File(configPath);
  var shellFileContents = await configFile.readAsString();

  final devtoolsToolBinPath =
      Constants.devToolsPATHExport.replaceAll('{{path}}', cloneDir);
  if (!shellFileContents.contains(devtoolsToolBinPath)) {
    shellFileContents += devtoolsToolBinPath;
    await F.writeKeyValueToRcConfig(
      configFile,
      RunCommandKey.devTools.key,
      cloneDir,
    );
    l.info(
        '\nAdded\n $devtoolsToolBinPath to PATH in ${configPath.split('/').last}.\n');
  }

  // Optional step: Check and update the DevTools Flutter SDK
  await F
      .runCommand('devtools_tool', ['update-flutter-sdk', '--update-on-path']);

  // Inform the user to restart their terminal
  l
    ..info(
        'Setup complete! Please restart your terminal or source your shell configuration to apply PATH changes.\n'
            .green)
    ..info('To verify the setup, run the following command:')
    ..info(
        '`flutter run` on a sample Flutter project and connect it to DevTools.');
  await displayIncrementalInfo();

  return ExitCode.success.code;
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
