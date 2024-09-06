import 'dart:convert';
import 'dart:io';


void main() async {
  print('Flutter Framework Development Environment Setup');

  // Determine the operating system
  final String os = Platform.operatingSystem;
  if (os != 'linux' && os != 'macos') {
    print('This tool supports only Linux and macOS platforms.');
    exit(1);
  }

  // Check prerequisites
  await checkPrerequisites(os);

  // Prompt for GitHub username
  String githubUsername = await promptUser('Enter your GitHub username: ');

  // Prompt for SSH or HTTPS
  String cloneMethod = await promptUser(
      'Choose clone method (1 for SSH, 2 for HTTPS) [Default: 1]: ',
      defaultValue: '1');

  // Clone the flutter/flutter repository
  String cloneUrl;
  if (cloneMethod == '2') {
    cloneUrl = 'https://github.com/flutter/flutter.git';
  } else {
    cloneUrl = 'git@github.com:flutter/flutter.git';
  }

  String cloneDir = await promptUser(
      'Enter the directory to clone the Flutter repository [Default: \$HOME/flutter]: ',
      defaultValue: '${Platform.environment['HOME']}/flutter');

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
  String flutterBinPath = '$cloneDir/bin';
  await addToPath(flutterBinPath);

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

/// Checks if the required prerequisites are installed.
Future<void> checkPrerequisites(String os) async {
  print('\nChecking prerequisites...');

  // Check Git
  if (!await isCommandAvailable('git')) {
    print('Error: git is not installed. Please install Git and try again.');
    exit(1);
  }
  print('✔ Git is installed.');

  // Check Python
  if (!await isCommandAvailable('python3')) {
    print(
        'Error: Python3 is not installed. Please install Python and try again.');
    exit(1);
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
      exit(1);
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
    exit(1);
  }
  print('✔ adb is available in PATH.');
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

/// Adds a directory to the user's PATH by modifying shell configuration files.
Future<void> addToPath(String flutterBinPath) async {
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

  String exportLine =
      '\n# Added by Flutter setup CLI\nexport PATH="\$PATH:$flutterBinPath"\n';

  File configFile = File(configPath);
  if (await configFile.exists()) {
    String contents = await configFile.readAsString();
    if (!contents.contains(flutterBinPath)) {
      await configFile.writeAsString(exportLine, mode: FileMode.append);
      print('✔ Added Flutter bin directory to PATH in $shellConfig.');
    } else {
      print('✔ Flutter bin directory is already in PATH.');
    }
  } else {
    print('Warning: Shell configuration file $shellConfig not found.');
  }
}

/// Runs a Flutter command using the cloned Flutter repository.
Future<void> runFlutterCommand(List<String> args) async {
  String flutterExecutable = './bin/flutter';
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
