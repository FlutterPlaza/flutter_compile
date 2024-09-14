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
    await setupDevToolsEnvironment(_logger);
    return ExitCode.success.code;
  }
}

// Future<void> setupDevToolsEnvironment(Logger l) async {
//   l.info('DevTools Development Environment Setup'.blue);

//   // Check if flutter and dart are in PATH
//   if (!await F.isCommandAvailable('flutter') ||
//       !await F.isCommandAvailable('dart')) {
//     l.err(
//         'Error: flutter and dart must be in your PATH. Please ensure Flutter SDK is correctly installed and added to PATH.');
//     exit(ExitCode.unavailable.code);
//   }

//   // Fork and clone the DevTools repo
//   String githubUsername = await F.getGihHubName();

//   String cloneMethod = await F.promptUser(
//       'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
//       defaultValue: '1');
//   String cloneUrl = cloneMethod == '2'
//       ? 'https://github.com/flutter/devtools.git'
//       : 'git@github.com:flutter/devtools.git';
//   String clonePath =
//       '${Platform.environment['HOME']}${Constants.devToolsInstallPath}';
//   String cloneDir = await F.promptUser(
//       'Enter the directory to clone the DevTools repository [Default: $clonePath]: ',
//       defaultValue: clonePath);

//   await F.cloneRepository(cloneUrl, cloneDir);
//   Directory.current = cloneDir;

//   await F.runCommand('git',
//       ['remote', 'add', 'upstream', 'https://github.com/flutter/devtools.git']);
//   await F.runCommand('git', ['fetch', 'upstream']);
//   await F.runCommand(
//       'git', ['branch', '--set-upstream-to=upstream/master', 'master']);

//   final forkUrl = cloneMethod == '2'
//       ? 'https://github.com/$githubUsername/devtools.git'
//       : 'git@github.com:$githubUsername/devtools.git';
//   await F.runCommand('git', ['remote', 'add', 'origin', forkUrl]);

//   // Ensure access to devtools_tool executable
//   Directory toolDir = Directory('$cloneDir/tool');
//   if (!await toolDir.exists()) {
//     l.err('Error: devtools/tool directory not found.');
//     exit(ExitCode.unavailable.code);
//   }

//   await F.runCommand(
//     'flutter',
//     ['pub', 'get', '--directory', toolDir.path],
//   );

//   // Add devtools/tool/bin to PATH
//   final String shell = Platform.environment['SHELL'] ?? '';
//   final String shellConfig = shell.contains('bash')
//       ? '.bashrc'
//       : shell.contains('zsh')
//           ? '.zshrc'
//           : '.profile';
//   final String home = Platform.environment['HOME'] ?? '';
//   final String configPath = '$home/$shellConfig';
//   final File configFile = File(configPath);
//   String shellFileContents = await configFile.readAsString();

//   final devtoolsToolBinPath =
//       Constants.devToolsPATHExport.replaceAll('{{path}}', cloneDir);
//   if (!shellFileContents.contains(devtoolsToolBinPath)) {
//     shellFileContents += devtoolsToolBinPath;
//     await F.writeKeyValueToRcConfig(
//         configFile, RunCommandKey.devTools.key, cloneDir);
//     l.info('\nAdded\n $devtoolsToolBinPath to PATH in $shellConfig.\n');
//   }

//   l.info(
//       'Setup complete! Please restart your terminal or source your shell configuration to apply PATH changes.\n'
//           .green);
// }


Future<void> setupDevToolsEnvironment(Logger l) async {
  l.info('DevTools Development Environment Setup'.blue);

  // Check if Flutter and Dart are in PATH and verify the correct versions
  if (!await F.isCommandAvailable('flutter') || !await F.isCommandAvailable('dart')) {
    l.err(
      'Error: flutter and dart must be in your PATH. Please ensure Flutter SDK is correctly installed and added to PATH.'
    );
    exit(ExitCode.unavailable.code);
  }

  // // Verify Flutter SDK version matches the DevTools requirement
  // String flutterVersion = await F.runCommand('flutter', ['--version']);
  // if (!flutterVersion.contains('X.Y.Z')) {  // Replace with actual version checks
  //   l.err('Incorrect Flutter version. Please install the required Flutter SDK version.');
  //   exit(ExitCode.unavailable.code);
  // }

  // Clone the DevTools repo
  String githubUsername = await F.getGihHubName();

  String cloneMethod = await F.promptUser(
    'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
    defaultValue: '1'
  );
  String cloneUrl = cloneMethod == '2'
    ? 'https://github.com/flutter/devtools.git'
    : 'git@github.com:flutter/devtools.git';
  String clonePath = '${Platform.environment['HOME']}${Constants.devToolsInstallPath}';
  String cloneDir = await F.promptUser(
    'Enter the directory to clone the DevTools repository [Default: $clonePath]: ',
    defaultValue: clonePath
  );

  await F.cloneRepository(cloneUrl, cloneDir);
  Directory.current = cloneDir;

  // Add upstream remote and set up tracking branch
  await F.runCommand('git', ['remote', 'add', 'upstream', 'https://github.com/flutter/devtools.git']);
  await F.runCommand('git', ['fetch', 'upstream']);
  await F.runCommand('git', ['branch', '--set-upstream-to=upstream/master', 'master']);

  // Add origin remote (for the user's fork)
  final forkUrl = cloneMethod == '2'
    ? 'https://github.com/$githubUsername/devtools.git'
    : 'git@github.com:$githubUsername/devtools.git';
  await F.runCommand('git', ['remote', 'add', 'origin', forkUrl]);

  // Ensure the DevTools 'tool' directory exists
  Directory toolDir = Directory('$cloneDir/tool');
  if (!await toolDir.exists()) {
    l.err('Error: devtools/tool directory not found.');
    exit(ExitCode.unavailable.code);
  }

  // Run Flutter pub get for the tool directory
  await F.runCommand(
    'flutter',
    ['pub', 'get', '--directory', toolDir.path]
  );

  // Add the DevTools tool bin to the PATH
  final String shell = Platform.environment['SHELL'] ?? '';
  final String shellConfig = shell.contains('bash')
    ? '.bashrc'
    : shell.contains('zsh')
        ? '.zshrc'
        : '.profile';
  final String home = Platform.environment['HOME'] ?? '';
  final String configPath = '$home/$shellConfig';
  final File configFile = File(configPath);
  String shellFileContents = await configFile.readAsString();

  final devtoolsToolBinPath = Constants.devToolsPATHExport.replaceAll('{{path}}', cloneDir);
  if (!shellFileContents.contains(devtoolsToolBinPath)) {
    shellFileContents += devtoolsToolBinPath;
    await F.writeKeyValueToRcConfig(
        configFile, RunCommandKey.devTools.key, cloneDir);
    l.info('\nAdded\n $devtoolsToolBinPath to PATH in $shellConfig.\n');
  }

  // Optional step: Check and update the DevTools Flutter SDK
  await F.runCommand('devtools_tool', ['update-flutter-sdk', '--update-on-path']);

  // Inform the user to restart their terminal
  l..info('Setup complete! Please restart your terminal or source your shell configuration to apply PATH changes.\n'.green)

  // Prompt the user to verify the setup by running DevTools
  ..info('To verify the setup, run the following command:')
  ..info('`flutter run` on a sample Flutter project and connect it to DevTools.');
  await displayIncrementalInfo();
}




Future<void> displayIncrementalInfo() async {
  final lenght = Constants.infoSections.length;
  for (int i = 0; i < lenght; i++) {
    final section = Constants.infoSections[i];
    stdout..writeln(section)
    ..writeln('[${i + 1}/$lenght]Press Enter to continue...'.blue);
    stdin.readLineSync();
  }
}
