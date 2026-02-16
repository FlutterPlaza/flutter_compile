import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:mason_logger/mason_logger.dart';

class F {
  const F();

  static Logger logger = Logger();

  static Future<String> getPersistedPathFromRC({
    required RunCommandKey key,
    String? preferredPath,
  }) async {
    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');
    logger.info(
      '\nChecking for persisted ${key.key} path in ~/.flutter_compilerc\n',
    );

    if (key == RunCommandKey.flutterCompile) {
      if (preferredPath != null) {
        await writeKeyValueToRcConfig(rcConfigFile, key.key, preferredPath);
        return preferredPath;
      }

      if (await rcConfigFile.exists()) {
        final persistedPath =
            await readValueForKeyFromRcConfig(rcConfigFile, key.key);
        if (persistedPath != null) {
          return persistedPath;
        }
      }

      final defaultPath = '$home${Constants.flutterCompileBin}';
      await writeKeyValueToRcConfig(rcConfigFile, key.key, defaultPath);
      return defaultPath;
    }
    return '';
  }

  static Future<void> runCommand(
    String command,
    List<String> args, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    logger.info('\$ $command ${args.join(' ')}');
    final process = await Process.start(
      command,
      args,
      runInShell: true,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    process.stdout.transform(utf8.decoder).listen((data) => stdout.write(data));
    process.stderr.transform(utf8.decoder).listen((data) => stderr.write(data));
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      final message =
          'Error: Command "$command ${args.join(' ')}" exited with code $exitCode.';
      logger.info(message);
      throw FlutterCompileException(message, exitCode: exitCode);
    }
  }

  /// Returns the path to the user's shell config file (e.g. /Users/foo/.zshrc).
  static String getShellConfigPath() {
    final home = Platform.environment['HOME'] ?? '';
    final shell = Platform.environment['SHELL'] ?? '';
    final shellConfig = shell.contains('bash')
        ? '.bashrc'
        : shell.contains('zsh')
            ? '.zshrc'
            : '.profile';
    return '$home/$shellConfig';
  }

  static Future<String> getHostCpuArch() async {
    final result = await Process.run('uname', ['-m']);
    return (result.stdout as String).trim();
  }

  static Future<void> writeFile(String path, String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  static Future<void> runFlutterCommand(
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    final flutterExecutable =
        '${await getPersistedPathFromRC(key: RunCommandKey.flutterCompile)}/flutter';
    if (!await File(flutterExecutable).exists()) {
      final message =
          'Error: Flutter executable not found at $flutterExecutable.';
      logger.info(message);
      throw FlutterCompileException(
        message,
        exitCode: ExitCode.unavailable.code,
      );
    }
    await runCommand(flutterExecutable, args, environment: environment);
  }

  static Future<void> checkPrerequisites(String os) async {
    logger.info('\nChecking prerequisites...');
    if (!await isCommandAvailable('git')) {
      const message =
          'Error: git is not installed. Please install Git and try again.';
      logger.err(message);
      throw FlutterCompileException(
        message,
        exitCode: ExitCode.unavailable.code,
      );
    }
    logger.success('✔ Git is installed.'.green);

    if (!await isCommandAvailable('python3')) {
      const message =
          'Error: Python3 is not installed. Please install Python and try again.';
      logger.err(message);
      throw FlutterCompileException(
        message,
        exitCode: ExitCode.unavailable.code,
      );
    }
    logger.success('✔ Python3 is installed.'.green);

    if (!await isCommandAvailable('studio')) {
      logger.info(
        'Warning: Android Studio does not seem to be installed or not in PATH.\n',
      );
    } else if (!await isCommandAvailable('code')) {
      logger.warn(
        'Warning: VS Code does not seem to be installed or not in PATH.\n',
      );
    }

    logger.info('\nInstalling Android platform tools...');
    if (os == 'macos') {
      if (!await isCommandAvailable('brew')) {
        const message =
            'Error: Homebrew is not installed. Please install Homebrew and try again.';
        logger.err(message);
        throw FlutterCompileException(
          message,
          exitCode: ExitCode.unavailable.code,
        );
      }
      await runCommand('brew', ['install', '--cask', 'android-platform-tools']);
    } else if (os == 'linux') {
      await runCommand('sudo', ['apt-get', 'update']);
      await runCommand(
        'sudo',
        ['apt-get', 'install', '-y', 'android-tools-adb'],
      );
    }

    if (!await isCommandAvailable('adb')) {
      const message =
          'Error: adb is not in your PATH. Please ensure Android platform tools are correctly installed.';
      logger.err(message);
      throw FlutterCompileException(
        message,
        exitCode: ExitCode.unavailable.code,
      );
    }
    logger.success('✔ adb is available in PATH.'.green);
  }

  static Future<String> promptUser(
    String prompt, {
    String defaultValue = '',
  }) async {
    stdout.write(prompt);
    final input = stdin.readLineSync();
    return input == null || input.trim().isEmpty ? defaultValue : input.trim();
  }

  static Future<bool> isCommandAvailable(String command) async {
    try {
      final result = await Process.run('which', [command]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  static Future<String> getGitHubName() async {
    var githubUsername = await _getGitHubUsername();
    var hasMatch = false;
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
      final result = await Process.run('git', ['config', 'user.email']);
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
      final flutterCompilePath = await F.getPersistedPathFromRC(
        key: RunCommandKey.flutterCompile,
      );

      final configPath = F.getShellConfigPath();
      final configFile = File(configPath);
      var contents = await configFile.readAsString();

      final flutterCompilePATHExport = Constants.flutterCompilePATHExport
          .replaceAll('{{path}}', flutterCompilePath);

      final isUsingCompiledVersion =
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
        logger.success(
          isUsingCompiledVersion
              ? Constants.flutterCompileSwitchedToNormal
              : Constants.flutterCompileSwitchedToCompiled,
        );
      } else {
        logger.info(
          'Is already using ${mode == FlutterMode.compiled ? 'compiled' : 'normal'} version.'
              .green,
        );
        return;
      }

      logger.info(Constants.restartShell
          .replaceAll('{{shell}}', configPath.split('/').last));
    } catch (e) {
      final message = 'Error: $e';
      logger.err(message);
      throw FlutterCompileException(message, exitCode: ExitCode.software.code);
    }
  }

  static Future<void> cloneRepository(String url, String directory) async {
    final dir = Directory(directory);
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
    File file,
    String key,
    String value,
  ) async {
    final keyValuePairs = <String, String>{};

    if (await file.exists()) {
      final lines = await file.readAsLines();
      for (var line in lines) {
        final parts = line.split(':');
        if (parts.length == 2) {
          keyValuePairs[parts[0]] = parts[1];
        }
      }
    }

    keyValuePairs[key] = value;

    final buffer = StringBuffer();
    keyValuePairs.forEach((k, v) {
      buffer.writeln('$k:$v');
    });

    await file.writeAsString(buffer.toString());
  }

  static Future<String?> readValueForKeyFromRcConfig(
    File file,
    String key,
  ) async {
    if (await file.exists()) {
      final lines = await file.readAsLines();
      for (var line in lines) {
        final parts = line.split(':');
        if (parts.length == 2 && parts[0] == key) {
          return parts[1];
        }
      }
    }
    return null;
  }

  // SDK resolution helpers

  static String sdkPubCachePath(String sdkPath) => '$sdkPath/.pub-cache';

  static Map<String, String> sdkEnvironment(String sdkPath) =>
      {'PUB_CACHE': sdkPubCachePath(sdkPath)};

  static String sdkVersionPath(String version) {
    final home = Platform.environment['HOME'] ?? '';
    return '$home${Constants.sdkVersionsPath}/$version';
  }

  static bool isSdkInstalled(String version) =>
      Directory(sdkVersionPath(version)).existsSync();

  static Future<String?> readProjectSdkVersion([String? directory]) async {
    final dir = directory ?? Directory.current.path;
    final file = File('$dir/${Constants.flutterVersionFile}');
    if (await file.exists()) {
      final content = (await file.readAsString()).trim();
      return content.isEmpty ? null : content;
    }
    return null;
  }

  static Future<String?> readGlobalSdkVersion() async {
    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');
    return readValueForKeyFromRcConfig(
      rcConfigFile,
      Constants.globalSdkVersionKey,
    );
  }

  static Future<String?> resolveActiveSdkVersion() async {
    return await readProjectSdkVersion() ?? await readGlobalSdkVersion();
  }
}
