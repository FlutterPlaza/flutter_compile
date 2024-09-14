import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:mason_logger/mason_logger.dart';

class F {
  const F();

  static Logger logger = Logger();

  static Future<String> getPersistedPathFromRC({
    required RunCommandKey key,
    String? preferredPath,
  }) async {
    final String home = Platform.environment['HOME'] ?? '';
    final File rcConfigFile = File('$home/.flutter_compilerc');
    logger.info(
        '\nChecking for persisted ${key.key} path in ~/.flutter_compilerc\n');

    if (key == RunCommandKey.flutterCompile) {
      if (preferredPath != null) {
        await writeKeyValueToRcConfig(rcConfigFile, key.key, preferredPath);
        return preferredPath;
      }

      if (await rcConfigFile.exists()) {
        final String? persistedPath =
            await readValueForKeyFromRcConfig(rcConfigFile, key.key);
        if (persistedPath != null) {
          return persistedPath;
        }
      }

      final String defaultPath = '$home${Constants.flutterCompileBin}';
      await writeKeyValueToRcConfig(rcConfigFile, key.key, defaultPath);
      return defaultPath;
    }
    return '';
  }

  static Future<void> runCommand(
    String command,
    List<String> args,
  ) async {
    logger.info('\$ $command ${args.join(' ')}');
    final Process process =
        await Process.start(command, args, runInShell: true);
    process.stdout.transform(utf8.decoder).listen((data) => stdout.write(data));
    process.stderr.transform(utf8.decoder).listen((data) => stderr.write(data));
    final int exitCode = await process.exitCode;
    if (exitCode != 0) {
      logger.info(
          'Error: Command "$command ${args.join(' ')}" exited with code $exitCode.');
      exit(exitCode);
    }
  }

  static Future<void> runFlutterCommand(List<String> args) async {
    final flutterExecutable =
        await getPersistedPathFromRC(key: RunCommandKey.flutterCompile) +
            '/flutter';
    if (!await File(flutterExecutable).exists()) {
      logger.info('Error: Flutter executable not found at $flutterExecutable.');
      exit(1);
    }
    await runCommand(flutterExecutable, args);
  }

  static Future<void> checkPrerequisites(String os) async {
    logger.info('\nChecking prerequisites...');
    if (!await isCommandAvailable('git')) {
      logger.err(
          'Error: git is not installed. Please install Git and try again.');
      exit(ExitCode
          .unavailable.code); // Using ExitCode.unavailable for git not found
    }
    logger.success('✔ Git is installed.'.green);

    if (!await isCommandAvailable('python3')) {
      logger.err(
          'Error: Python3 is not installed. Please install Python and try again.');
      exit(ExitCode.unavailable
          .code); // Using ExitCode.unavailable for python3 not found
    }
    logger.success('✔ Python3 is installed.'.green);

    if (!await isCommandAvailable('studio')) {
      logger.info(
          'Warning: Android Studio does not seem to be installed or not in PATH.\n');
    } else if (!await isCommandAvailable('code')) {
      logger.warn(
          'Warning: VS Code does not seem to be installed or not in PATH.\n');
    }

    logger.info('\nInstalling Android platform tools...');
    if (os == 'macos') {
      if (!await isCommandAvailable('brew')) {
        logger.err(
            'Error: Homebrew is not installed. Please install Homebrew and try again.');
        exit(ExitCode
            .unavailable.code); // Using ExitCode.unavailable for brew not found
      }
      await runCommand('brew', ['install', '--cask', 'android-platform-tools']);
    } else if (os == 'linux') {
      await runCommand('sudo', ['apt-get', 'update']);
      await runCommand(
          'sudo', ['apt-get', 'install', '-y', 'android-tools-adb']);
    }

    if (!await isCommandAvailable('adb')) {
      logger.err(
          'Error: adb is not in your PATH. Please ensure Android platform tools are correctly installed.');
      exit(ExitCode
          .unavailable.code); // Using ExitCode.unavailable for adb not found
    }
    logger.success('✔ adb is available in PATH.'.green);
  }

  static Future<String> promptUser(String prompt,
      {String defaultValue = ''}) async {
    stdout.write(prompt);
    final String? input = stdin.readLineSync();
    return input == null || input.trim().isEmpty ? defaultValue : input.trim();
  }

  static Future<bool> isCommandAvailable(String command) async {
    try {
      final ProcessResult result = await Process.run('which', [command]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  static Future<String> getGihHubName() async {
    String githubUsername = await _getGitHubUsername();
    bool hasMatch = false;
    do {
      githubUsername = await F.promptUser(
        'Enter your GitHub username [Default: $githubUsername]: ',
        defaultValue: githubUsername,
      );

      hasMatch = RegExp(Constants.gitHubUserNameRegex).hasMatch(githubUsername);

      if (!hasMatch) {
        logger.err('Invalid GitHub username. Please enter a valid username.');
      }
    } while (!hasMatch);

    return githubUsername;
  }

 static Future<String> _getGitHubUsername() async {
    try {
      final ProcessResult result =
          await Process.run('git', ['config', 'user.email']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim().split('@').first;
      }
    } catch (e) {
      // Handle error if needed
    }
    return '';
  }

  static Future<void> switchFlutterEnvironment({FlutterMode? mode}) async {
    try {
      final String flutterCompilePath = await F.getPersistedPathFromRC(
        key: RunCommandKey.flutterCompile,
      );

      final String shell = Platform.environment['SHELL'] ?? '';
      final String shellConfig = shell.contains('bash')
          ? '.bashrc'
          : shell.contains('zsh')
              ? '.zshrc'
              : '.profile';
      final String home = Platform.environment['HOME'] ?? '';
      final String configPath = '$home/$shellConfig';
      final File configFile = File(configPath);
      String contents = await configFile.readAsString();

      final flutterCompilePATHExport = Constants.flutterCompilePATHExport
          .replaceAll('{{path}}', flutterCompilePath);

      final bool isUsingCompiledVersion =
          contents.contains(flutterCompilePATHExport);

      if (mode == FlutterMode.compiled && !isUsingCompiledVersion) {
        contents += flutterCompilePATHExport;
        await configFile.writeAsString(contents);
        logger.success(Constants.flutterCompileSwitchedToCompiled);
      } else if (mode == FlutterMode.normal && isUsingCompiledVersion) {
        contents = contents.replaceAll(flutterCompilePATHExport, '');
        await configFile.writeAsString(contents);
        logger.success(Constants.flutterCompileSwitchedToNormal);
      } else if (mode == null) {
        contents = isUsingCompiledVersion
            ? contents.replaceAll(flutterCompilePATHExport, '')
            : contents + flutterCompilePATHExport;
        await configFile.writeAsString(contents);
        logger.success(isUsingCompiledVersion
            ? Constants.flutterCompileSwitchedToNormal
            : Constants.flutterCompileSwitchedToCompiled);
      } else {
        logger.info(
            'Is already using ${mode == FlutterMode.compiled ? 'compiled' : 'normal'} version.'
                .green);
        return;
      }

      logger.info(Constants.restartShell.replaceAll('{{shell}}', shellConfig));
    } catch (e) {
      logger.err('Error: $e');
      exit(1);
    }
  }

  static Future<void> cloneRepository(String url, String directory) async {
    final Directory dir = Directory(directory);
    if (dir.existsSync()) {
      logger.info('Directory $directory already exists. Skipping clone.');
      return;
    }
    await runCommand(
      'git',
      ['clone', url, directory],
    );
  }

  static Future<void> writeKeyValueToRcConfig(
      File file, String key, String value) async {
    final Map<String, String> keyValuePairs = {};

    if (await file.exists()) {
      final List<String> lines = await file.readAsLines();
      for (String line in lines) {
        final List<String> parts = line.split(':');
        if (parts.length == 2) {
          keyValuePairs[parts[0]] = parts[1];
        }
      }
    }

    keyValuePairs[key] = value;

    final StringBuffer buffer = StringBuffer();
    keyValuePairs.forEach((k, v) {
      buffer.writeln('$k:$v');
    });

    await file.writeAsString(buffer.toString());
  }

  static Future<String?> readValueForKeyFromRcConfig(
      File file, String key) async {
    if (await file.exists()) {
      final List<String> lines = await file.readAsLines();
      for (String line in lines) {
        final List<String> parts = line.split(':');
        if (parts.length == 2 && parts[0] == key) {
          return parts[1];
        }
      }
    }
    return null;
  }
}
