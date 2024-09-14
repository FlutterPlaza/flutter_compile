import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class FlutterSubCommand extends Command<int> {
  FlutterSubCommand(this._logger) {
    argParser.addFlag(
      'flutter',
      abbr: 'f',
      help: 'Install Flutter environment',
    );
  }
  final Logger _logger;

  @override
  final String name = 'flutter';
  @override
  final String description = 'Set up the Flutter development environment';

  @override
  Future<int> run() async {
    await setupFlutterEnvironment(_logger);
    return ExitCode.success.code;
  }
}

Future<void> setupFlutterEnvironment(Logger l) async {
  l.info('Flutter Framework Development Environment Setup'.blue);
  final os = Platform.operatingSystem;
  if (os != 'linux' && os != 'macos') {
    l.err('This tool supports only Linux and macOS platforms.');
    exit(ExitCode.usage.code); // Using ExitCode.usage for unsupported OS
  }

  await F.checkPrerequisites(os);
  final cloneMethod = await F.promptUser(
    'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
    defaultValue: '1',
  );

  String githubUsername = await F.getGihHubName();

  final cloneUrl = cloneMethod == '2'
      ? 'https://github.com/flutter/flutter.git'
      : 'git@github.com:flutter/flutter.git';
  final clonePath =
      '${Platform.environment['HOME']}${Constants.flutterCompileInstallPath}';
  final cloneDir = await F.promptUser(
    'Enter the directory to clone the Flutter repository [Default: $clonePath]: ',
    defaultValue: clonePath,
  );

  await F.cloneRepository(cloneUrl, cloneDir);
  Directory.current = cloneDir;

  await F.runCommand('git', ['remote', 'rename', 'origin', 'upstream']);
  l.info(
    '\nPlease ensure you have forked the flutter/flutter repository on GitHub.',
  );

  final forkUrl = cloneMethod == '2'
      ? 'https://github.com/$githubUsername/flutter.git'
      : 'git@github.com:$githubUsername/flutter.git';
  await F.runCommand('git', ['remote', 'add', 'origin', forkUrl]);

  l.info('\nVerifying remotes:');
  await F.runCommand('git', ['remote', '-v']);
  await F.runFlutterCommand(['update-packages']);

  final configureIDE = await F.promptUser(
    'Do you want to configure IDE settings for IntelliJ? (y/n) [Default: n]: ',
    defaultValue: 'n',
  );
  if (configureIDE.toLowerCase() == 'y') {
    await F.runFlutterCommand(['ide-config', '--overwrite']);
  }

  l
    ..info(
      '\nSetup complete! Please restart your terminal or source your shell configuration to apply PATH changes.'
          .green,
    )
    ..info('\nRun\n')
    ..info(
      'flutter_compile switch compiled'.blue,
    )
    ..info(
      '\nto switch to the compiled Flutter installation.',
    );
}
