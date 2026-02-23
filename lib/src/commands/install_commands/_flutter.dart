import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class FlutterSubCommand extends Command<int> {
  FlutterSubCommand(this._logger) {
    argParser
      ..addFlag(
        'flutter',
        abbr: 'f',
        help: 'Install Flutter environment',
      )
      ..addOption(
        'ide',
        help: 'Calling IDE (vscode, intellij). '
            'Skips or auto-accepts IDE-specific prompts.',
        allowed: ['vscode', 'intellij'],
      );
  }
  final Logger _logger;

  @override
  final String name = 'flutter';
  @override
  final String description = 'Set up the Flutter development environment';

  @override
  Future<int> run() async {
    final ide = argResults?['ide'] as String?;
    return setupFlutterEnvironment(_logger, ide: ide);
  }
}

Future<int> setupFlutterEnvironment(Logger l, {String? ide}) async {
  l.info('Flutter Framework Development Environment Setup'.blue);
  final os = Platform.operatingSystem;
  if (os != 'linux' && os != 'macos' && os != 'windows') {
    l.err('This tool supports only Linux, macOS, and Windows platforms.');
    return ExitCode.usage.code;
  }

  await F.checkPrerequisites(os);
  final cloneMethod = await F.promptUser(
    'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
    defaultValue: '1',
  );

  var githubUsername = await F.getGitHubName();

  final cloneUrl = cloneMethod == '2'
      ? 'https://github.com/flutter/flutter.git'
      : 'git@github.com:flutter/flutter.git';
  final clonePath = '${F.homeDir()}${Constants.flutterCompileInstallPath}';
  final cloneDir = await F.promptUser(
    'Enter the directory to clone the Flutter repository [Default: $clonePath]: ',
    defaultValue: clonePath,
  );

  await F.cloneRepository(cloneUrl, cloneDir);
  Directory.current = cloneDir;

  // Save flutter path to .flutter_compilerc so doctor can detect it
  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');
  await F.writeKeyValueToRcConfig(
    rcConfigFile,
    RunCommandKey.flutterCompile.key,
    cloneDir,
  );
  l.info('Saved flutter path to .flutter_compilerc.'.green);

  // Set up git remotes (idempotent — safe to re-run)
  l.info(
    '\nPlease ensure you have forked the flutter/flutter repository on GitHub.',
  );
  final upstreamUrl = cloneMethod == '2'
      ? 'https://github.com/flutter/flutter.git'
      : 'git@github.com:flutter/flutter.git';
  final forkUrl = cloneMethod == '2'
      ? 'https://github.com/$githubUsername/flutter.git'
      : 'git@github.com:$githubUsername/flutter.git';
  await _ensureRemote(l, 'upstream', upstreamUrl, cloneDir);
  await _ensureRemote(l, 'origin', forkUrl, cloneDir);

  l.info('\nVerifying remotes:');
  await F.runCommand('git', ['remote', '-v'], workingDirectory: cloneDir);
  await F.runFlutterCommand(['update-packages']);

  // IDE config: `flutter ide-config` generates IntelliJ project files.
  // When called from VS Code, skip entirely (not applicable).
  // When called from IntelliJ, auto-accept.
  // Otherwise, prompt interactively.
  if (ide == 'intellij') {
    l.info('\nConfiguring IntelliJ IDE settings...');
    await F.runFlutterCommand(['ide-config', '--overwrite']);
  } else if (ide != 'vscode') {
    final configureIDE = await F.promptUser(
      'Do you want to configure IDE settings for IntelliJ? (y/n) [Default: n]: ',
      defaultValue: 'n',
    );
    if (configureIDE.toLowerCase() == 'y') {
      await F.runFlutterCommand(['ide-config', '--overwrite']);
    }
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
    final currentUrl = (result.stdout as String).trim();
    if (currentUrl != url) {
      await F.runCommand('git', ['remote', 'set-url', name, url],
          workingDirectory: workingDirectory);
      l.info('Updated remote "$name" to $url'.green);
    } else {
      l.info('Remote "$name" already set to $url'.green);
    }
  } else {
    await F.runCommand('git', ['remote', 'add', name, url],
        workingDirectory: workingDirectory);
    l.info('Added remote "$name" → $url'.green);
  }
}
