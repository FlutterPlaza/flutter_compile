import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/version.dart';

const flutterCompilePath = '/flutter_compile/flutter/';

enum ExitErrorCode {
  noArgumentProvided(1),
  unknownArgumentProvided(2),
  unsupportedOS(3),
  adbInstallFailed(4),
  adbNotFound(5),
  phython3NotInstalled(6),
  gitNotInstalled(7);

  final int code;
  const ExitErrorCode(this.code);
}

void main(List<String> arguments) async {
  // if no argument is passed, then exit with usage response
  if (arguments.isEmpty) {
    printUsage();
    exit(ExitErrorCode.noArgumentProvided.code);
  }
  // if `flutter_compile switch` then change from normal flutter installation to compile installation and vice versa
  if (arguments.isNotEmpty && arguments[0].toLowerCase() == 'switch') {
    String home = Platform.environment['HOME'] ?? '';
    File compileConfigFile = File('$home/.flutter_compilerc');
    if (await compileConfigFile.exists()) {
      final compilePath = await compileConfigFile.readAsString();
      await switchFlutterEnvironment(compilePath);
    } else {
      await switchFlutterEnvironment();
    }
    return;
  }

  // if `flutter_compile --version` then print version and exit

  if (arguments.isNotEmpty && arguments[0].toLowerCase() == '--version') {
    print('flutter_compile version $packageVersion');
    return;
  }
  // if `flutter_compile --help` then print usage and exit
  if (arguments.isNotEmpty && arguments[0].toLowerCase() == '--help') {
    printUsage();
    return;
  }

  // if `flutter_compile run` then start
  if (arguments.isNotEmpty && arguments[0].toLowerCase() != 'run') {
    printUsage();
    exit(ExitErrorCode.unknownArgumentProvided.code);
  }

  print('Flutter Framework Development Environment Setup');

  // Determine the operating system
  final String os = Platform.operatingSystem;
  if (os != 'linux' && os != 'macos') {
    print('This tool supports only Linux and macOS platforms.');
    exit(ExitErrorCode.unsupportedOS.code);
  }

  // Check prerequisites
  await checkPrerequisites(os);

  // Prompt for SSH or HTTPS
  String cloneMethod = await promptUser(
      'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
      defaultValue: '1');

  // Fetch GitHub username from git config
  String githubUsername = await getGitHubUsername();
  // Prompt for GitHub username
  githubUsername = await promptUser(
      'Enter your GitHub username [Default: $githubUsername]: ',
      defaultValue: githubUsername);
  // Clone the flutter/flutter repository
  String cloneUrl;
  if (cloneMethod == '2') {
    cloneUrl = 'https://github.com/flutter/flutter.git';
  } else {
    cloneUrl = 'git@github.com:flutter/flutter.git';
  }

  final clonePath = '${Platform.environment['HOME']}$flutterCompilePath';

  String cloneDir = await promptUser(
      'Enter the directory to clone the Flutter repository [Default: $clonePath]: ',
      defaultValue: clonePath);

  await cloneRepository(cloneUrl, cloneDir);

  // Change directory to cloned repository
  Directory flutterDir = Directory(cloneDir);
  if (!flutterDir.existsSync()) {
    print('Cloned directory does not exist. Exiting.');
    exit(1);
  }
  Directory.current = flutterDir.path;

  // Rename origin to upstream
  await runCommand('git', ['remote', 'rename', 'origin', 'upstream']);

  // Prompt to fork and add origin
  print(
      '\nPlease ensure you have forked the flutter/flutter repository on GitHub.');
  String forkedCloneMethod = await promptUser(
      'Choose clone method for your fork (1 for SSH, 2 for HTTPS) [Default: 1]: ',
      defaultValue: '1');

  String forkUrl;
  if (forkedCloneMethod == '2') {
    forkUrl = 'https://github.com/$githubUsername/flutter.git';
  } else {
    forkUrl = 'git@github.com:$githubUsername/flutter.git';
  }

  await runCommand('git', ['remote', 'add', 'origin', forkUrl]);

  // Verify remotes
  print('\nVerifying remotes:');
  await runCommand('git', ['remote', '-v']);

  // Add Flutter bin to PATH
  await switchFlutterEnvironment(cloneDir);

  // Update Flutter packages
  await runFlutterCommand(['update-packages']);

  // Optional: Configure IDE settings
  String configureIDE = await promptUser(
      'Do you want to configure IDE settings for IntelliJ? (y/n) [Default: n]: ',
      defaultValue: 'n');
  if (configureIDE.toLowerCase() == 'y') {
    await runFlutterCommand(['ide-config', '--overwrite']);
  }

  print(
      '\nSetup complete! Please restart your terminal or source your shell configuration to apply PATH changes.');
}

/// Prompts the user for input with an optional default value.
Future<String> promptUser(String prompt, {String defaultValue = ''}) async {
  stdout.write(prompt);
  String? input = stdin.readLineSync();
  if (input == null || input.trim().isEmpty) {
    return defaultValue;
  }
  return input.trim();
}

/// Checks if a command is available in the system PATH.
Future<bool> isCommandAvailable(String command) async {
  try {
    ProcessResult result = await Process.run('which', [command]);
    if (result.exitCode == 0) {
      return true;
    }
    return false;
  } catch (e) {
    return false;
  }
}

/// Runs a system command and prints its output.
Future<void> runCommand(String command, List<String> args) async {
  print('\$ $command ${args.join(' ')}');
  Process process = await Process.start(command, args, runInShell: true);

  // Pipe stdout
  process.stdout.transform(utf8.decoder).listen((data) {
    stdout.write(data);
  });

  // Pipe stderr
  process.stderr.transform(utf8.decoder).listen((data) {
    stderr.write(data);
  });

  int exitCode = await process.exitCode;
  if (exitCode != 0) {
    print(
        'Error: Command "$command ${args.join(' ')}" exited with code $exitCode.');
    exit(exitCode);
  }
}

/// Runs a Flutter command using the cloned Flutter repository.
Future<void> runFlutterCommand(List<String> args) async {
  String flutterExecutable =
      '${Platform.environment['HOME']}$flutterCompilePath' + 'bin/flutter';
  if (!await File(flutterExecutable).exists()) {
    print('Error: Flutter executable not found at $flutterExecutable.');
    exit(1);
  }

  await runCommand(flutterExecutable, args);
}

/// Clones a Git repository to the specified directory.
Future<void> cloneRepository(String url, String directory) async {
  Directory dir = Directory(directory);
  if (dir.existsSync()) {
    print('Directory $directory already exists. Skipping clone.');
    return;
  }

  await runCommand('git', ['clone', url, directory]);
}

// Future<void> main(List<String> args) async {

//   await _flushThenExit(await FlutterCompileCommandRunner().run(args));
// }

/// Flushes the stdout and stderr streams, then exits the program with the given
/// status code.
///
/// This returns a Future that will never complete, since the program will have
/// exited already. This is useful to prevent Future chains from proceeding
/// after you've decided to exit.
Future<void> _flushThenExit(int status) {
  return Future.wait<void>([stdout.close(), stderr.close()])
      .then<void>((_) => exit(status));
}

Future<void> switchFlutterEnvironment([String? flutterBinPath]) async {
  try {
    // Check current Flutter installation path
    ProcessResult result = await Process.run(
      'which',
      ['flutter'],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      print('Error: Flutter is not installed.');
      exit(1);
    }

    String shell = Platform.environment['SHELL'] ?? '';
    String shellConfig;

    if (shell.contains('bash')) {
      shellConfig = '.bashrc';
    } else if (shell.contains('zsh')) {
      shellConfig = '.zshrc';
    } else {
      shellConfig = '.profile';
    }
    String home = Platform.environment['HOME'] ?? '';
    String configPath = '$home/$shellConfig';
    File configFile = File(configPath);
    String contents = await configFile.readAsString();

    String compilePath;
    if (flutterBinPath != null) {
      compilePath = flutterBinPath;
      // Persist the flutterBinPath in .flutter_compilerc
      File compileConfigFile = File('$home/.flutter_compilerc');
      await compileConfigFile.writeAsString(flutterBinPath);
    } else {
      // Read the persisted flutterBinPath from .flutter_compilerc if it exists
      File compileConfigFile = File('$home/.flutter_compilerc');
      if (await compileConfigFile.exists()) {
        compilePath = await compileConfigFile.readAsString();
      } else {
        compilePath = '$home$flutterCompilePath' + 'bin/flutter';
      }
    }

    final export = '''
# >>> Added by Flutter setup CLI >>>
export PATH="\$PATH:$compilePath"
alias flutter="$compilePath"
# <<< Added by flutter_compile CLI <<<
''';

    final commentedExport = '''
# >>> Added by Flutter setup CLI >>>
#export PATH="\$PATH:$compilePath"
#alias flutter="$compilePath"
# <<< Added by flutter_compile CLI <<<
''';

    // Determine if we are using the compiled version or the normal version
    bool isUsingCompiledVersion =
        await configFile.exists() && contents.contains(export);

    if (isUsingCompiledVersion) {
      // Switch to normal Flutter installation
      contents = contents.replaceAll(export, commentedExport);
      await configFile.writeAsString(contents);
      print('Switched to normal Flutter installation.');
    } else {
      // Switch to compiled Flutter installation
      if (await configFile.exists()) {
        if (!contents.contains(export)) {
          contents += '\n$export';
          await configFile.writeAsString(contents);
          print('Switched to compiled Flutter installation.');
        } else {
          contents = contents.replaceAll(commentedExport, export);
          await configFile.writeAsString(contents);
          print('Switched to compiled Flutter installation.');
        }
      } else {
        print('Warning: Shell configuration file $shellConfig not found.');
      }
    }

    print(
        'Please restart your terminal or source your shell configuration to apply changes. Run\n\n source ~/$shellConfig\n');
  } catch (e) {
    print('Error: $e');
    exit(1);
  }
}

/// Fetches the GitHub username from git config.
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

/// Checks if the required prerequisites are installed.
Future<void> checkPrerequisites(String os) async {
  print('\nChecking prerequisites...');

  // Check Git
  if (!await isCommandAvailable('git')) {
    print('Error: git is not installed. Please install Git and try again.');
    exit(ExitErrorCode.gitNotInstalled.code);
  }
  print('✔ Git is installed.');

  // Check Python
  if (!await isCommandAvailable('python3')) {
    print(
        'Error: Python3 is not installed. Please install Python and try again.');
    exit(ExitErrorCode.phython3NotInstalled.code);
  }
  print('✔ Python3 is installed.');

  // Check IDE
  String ide = await promptUser(
      'Which IDE are you using? (1 for Android Studio, 2 for VS Code) [Default: 2]: ',
      defaultValue: '2');
  if (ide == '1') {
    if (!await isCommandAvailable('studio')) {
      print(
          'Warning: Android Studio does not seem to be installed or not in PATH.');
    } else {
      print('✔ Android Studio is installed.');
    }
  } else {
    if (!await isCommandAvailable('code')) {
      print('Warning: VS Code does not seem to be installed or not in PATH.');
    } else {
      print('✔ VS Code is installed.');
    }
  }

  // Install Android platform tools
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

  // Verify adb is in PATH
  if (!await isCommandAvailable('adb')) {
    print(
        'Error: adb is not in your PATH. Please ensure Android platform tools are correctly installed.');
    exit(ExitErrorCode.adbNotFound.code);
  }
  print('✔ adb is available in PATH.');
}

void printUsage() {
  print('Usage: flutter_compile <command>');
  print('');
  print('Commands:');
  print('  run     Set up the Flutter development environment');
  print(
      '  switch  Switch between normal Flutter installation and compiled Flutter installation');
}
