import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/version.dart';

const installPath = '/flutter_compile/flutter';
const flutterCompilePath = '$installPath/bin';

enum ExitErrorCode {
  noArgumentProvided(1),
  unknownArgumentProvided(2),
  unsupportedOS(3),
  adbInstallFailed(4),
  adbNotFound(5),
  python3NotInstalled(6),
  gitNotInstalled(7);

  final int code;
  const ExitErrorCode(this.code);
}

void main(List<String> arguments) async {
  if (arguments.isEmpty) {
    printUsage();
    exit(ExitErrorCode.noArgumentProvided.code);
  }

  switch (arguments[0].toLowerCase()) {
    case 'switch':
      await switchFlutterEnvironment().whenComplete(() {
        Future.wait<void>([stdout.close(), stderr.close()]);
      });
      break;
    case '--version':
    case '-v':
    case 'v':
      print('flutter_compile version $packageVersion');
      break;
    case '--help':
    case '-h':
    case 'h':
      printUsage();
      break;
    case 'install':
    case '-i':
    case 'i':
      await setupFlutterEnvironment().whenComplete(() {
        Future.wait<void>([stdout.close(), stderr.close()]);
      });
      break;
    default:
      printUsage();
      exit(ExitErrorCode.unknownArgumentProvided.code);
  }
}

Future<void> switchFlutterEnvironment([String? flutterBinPath]) async {
  try {
    String compilePath =
        await _getPersistedCompilePath(flutterBinPath: flutterBinPath);

    ProcessResult result =
        await Process.run('which', ['flutter'], runInShell: true);
    if (result.exitCode != 0) {
      print('Error: Flutter is not installed.');
      exit(1);
    }

    String shell = Platform.environment['SHELL'] ?? '';
    String shellConfig = shell.contains('bash')
        ? '.bashrc'
        : shell.contains('zsh')
            ? '.zshrc'
            : '.profile';
    String home = Platform.environment['HOME'] ?? '';
    String configPath = '$home/$shellConfig';
    File configFile = File(configPath);
    String contents = await configFile.readAsString();

    final export = '''

# >>> Added by flutter_compile setup CLI >>>
export PATH=$compilePath:\$PATH
export PATH=$compilePath/cache/dart-sdk/bin:\$PATH
# <<< Added by flutter_compile setup CLI <<<

''';
    final commentedExport = '''

# >>> Added by flutter_compile setup CLI >>>
#export PATH=$compilePath:\$PATH
#export PATH=$compilePath/cache/dart-sdk/bin:\$PATH
# <<< Added by flutter_compile setup CLI <<<

''';

    bool isUsingCompiledVersion = contents.contains(export);
    if (isUsingCompiledVersion) {
      contents = contents.replaceAll(export, commentedExport);
    } else if (contents.contains(commentedExport)) {
      contents = contents.replaceAll(commentedExport, export);
    } else {
      contents += '$export';
    }
    await configFile.writeAsString(contents);

    print(isUsingCompiledVersion
        ? 'Switched to normal Flutter installation.'.green
        : 'Switched to compiled Flutter installation.'.green);
    print(
        '\nPlease restart your terminal or source your shell configuration to apply changes. Run\n\nsource ~/$shellConfig\n');
  } catch (e) {
    print('Error: $e');
    exit(1);
  }
}

Future<String> _getPersistedCompilePath({
  String? flutterBinPath,
}) async {
  String home = Platform.environment['HOME'] ?? '';
  File compileConfigFile = File('$home/.flutter_compilerc');
  print(
      '\nChecking for persisted flutter_compile path in ~/.flutter_compilerc\n');

  if (flutterBinPath != null) {
    await compileConfigFile.writeAsString(flutterBinPath);
    return flutterBinPath;
  }

  if (await compileConfigFile.exists()) {
    return await compileConfigFile.readAsString();
  }

  String defaultPath = '$home$flutterCompilePath';
  await compileConfigFile.writeAsString(defaultPath);
  return defaultPath;
}

Future<void> setupFlutterEnvironment() async {
  print('Flutter Framework Development Environment Setup'.blue);
  final String os = Platform.operatingSystem;
  if (os != 'linux' && os != 'macos') {
    print('This tool supports only Linux and macOS platforms.');
    exit(ExitErrorCode.unsupportedOS.code);
  }

  await checkPrerequisites(os);
  String cloneMethod = await promptUser(
      'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
      defaultValue: '1');
  String githubUsername = await getGitHubUsername();
  githubUsername = await promptUser(
      'Enter your GitHub username [Default: $githubUsername]: ',
      defaultValue: githubUsername);

  String cloneUrl = cloneMethod == '2'
      ? 'https://github.com/flutter/flutter.git'
      : 'git@github.com:flutter/flutter.git';
  String clonePath = '${Platform.environment['HOME']}$installPath';
  String cloneDir = await promptUser(
      'Enter the directory to clone the Flutter repository [Default: $clonePath]: ',
      defaultValue: clonePath);

  await cloneRepository(cloneUrl, cloneDir);
  Directory.current = cloneDir;

  await runCommand('git', ['remote', 'rename', 'origin', 'upstream']);
  print(
      '\nPlease ensure you have forked the flutter/flutter repository on GitHub.');
  String forkedCloneMethod = await promptUser(
      'Choose clone method for your fork (1 for SSH, 2 for HTTPS) [Default: 1]: ',
      defaultValue: '1');
  String forkUrl = forkedCloneMethod == '2'
      ? 'https://github.com/$githubUsername/flutter.git'
      : 'git@github.com:$githubUsername/flutter.git';
  await runCommand('git', ['remote', 'add', 'origin', forkUrl]);

  print('\nVerifying remotes:');
  await runCommand('git', ['remote', '-v']);
  await switchFlutterEnvironment('$cloneDir/bin');
  await runFlutterCommand(['update-packages']);

  String configureIDE = await promptUser(
      'Do you want to configure IDE settings for IntelliJ? (y/n) [Default: n]: ',
      defaultValue: 'n');
  if (configureIDE.toLowerCase() == 'y') {
    await runFlutterCommand(['ide-config', '--overwrite']);
  }

  print(
      '\nSetup complete! Please restart your terminal or source your shell configuration to apply PATH changes.'
          .green);
}

Future<String> promptUser(String prompt, {String defaultValue = ''}) async {
  stdout.write(prompt);
  String? input = stdin.readLineSync();
  return input == null || input.trim().isEmpty ? defaultValue : input.trim();
}

Future<bool> isCommandAvailable(String command) async {
  try {
    ProcessResult result = await Process.run('which', [command]);
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

Future<void> runCommand(String command, List<String> args) async {
  print('\$ $command ${args.join(' ')}');
  Process process = await Process.start(command, args, runInShell: true);
  process.stdout.transform(utf8.decoder).listen((data) => stdout.write(data));
  process.stderr.transform(utf8.decoder).listen((data) => stderr.write(data));
  int exitCode = await process.exitCode;
  if (exitCode != 0) {
    print(
        'Error: Command "$command ${args.join(' ')}" exited with code $exitCode.');
    exit(exitCode);
  }
}

Future<void> runFlutterCommand(List<String> args) async {
  String flutterExecutable = await _getPersistedCompilePath() + '/flutter';
  if (!await File(flutterExecutable).exists()) {
    print('Error: Flutter executable not found at $flutterExecutable.');
    exit(1);
  }
  await runCommand(flutterExecutable, args);
}

Future<void> cloneRepository(String url, String directory) async {
  Directory dir = Directory(directory);
  if (dir.existsSync()) {
    print('Directory $directory already exists. Skipping clone.');
    return;
  }
  await runCommand('git', ['clone', url, directory]);
}

Future<String> getGitHubUsername() async {
  try {
    ProcessResult result = await Process.run('git', ['config', 'user.email']);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim().split('@').first;
    }
  } catch (e) {
    // Handle error if needed
  }
  return '';
}

Future<void> checkPrerequisites(String os) async {
  print('\nChecking prerequisites...');
  if (!await isCommandAvailable('git')) {
    print('Error: git is not installed. Please install Git and try again.');
    exit(ExitErrorCode.gitNotInstalled.code);
  }
  print('✔ Git is installed.'.green);

  if (!await isCommandAvailable('python3')) {
    print(
        'Error: Python3 is not installed. Please install Python and try again.');
    exit(ExitErrorCode.python3NotInstalled.code);
  }
  print('✔ Python3 is installed.'.green);

  // String ide = await promptUser(
  //     'Which IDE are you using? (1 for Android Studio, 2 for VS Code) [Default: 2]: ',
  //     defaultValue: '2');
  if (!await isCommandAvailable('studio')) {
    print(
        'Warning: Android Studio does not seem to be installed or not in PATH.\n');
  } else if (!await isCommandAvailable('code')) {
    print('Warning: VS Code does not seem to be installed or not in PATH.\n');
  }

  print('\nInstalling Android platform tools...');
  if (os == 'macos') {
    if (!await isCommandAvailable('brew')) {
      print(
          'Error: Homebrew is not installed. Please install Homebrew and try again.');
      exit(ExitErrorCode.adbInstallFailed.code);
    }
    await runCommand('brew', ['install', '--cask', 'android-platform-tools']);
  } else if (os == 'linux') {
    await runCommand('sudo', ['apt-get', 'update']);
    await runCommand('sudo', ['apt-get', 'install', '-y', 'android-tools-adb']);
  }

  if (!await isCommandAvailable('adb')) {
    print(
        'Error: adb is not in your PATH. Please ensure Android platform tools are correctly installed.');
    exit(ExitErrorCode.adbNotFound.code);
  }
  print('✔ adb is available in PATH.'.green);
}

void printUsage() {
  print('Usage: flutter_compile <command>');
  print('');
  print('Commands:');
  print('  run     Set up the Flutter development environment');
  print(
      '  switch  Switch between normal Flutter installation and compiled Flutter installation');
}

extension ConsoleColor on String {
  String get red => '\x1B[31m$this\x1B[0m';
  String get green => '\x1B[32m$this\x1B[0m';
  String get yellow => '\x1B[33m$this\x1B[0m';
  String get blue => '\x1B[34m$this\x1B[0m';
  String get magenta => '\x1B[35m$this\x1B[0m';
  String get cyan => '\x1B[36m$this\x1B[0m';
  String get white => '\x1B[37m$this\x1B[0m';
}
