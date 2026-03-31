import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:mason_logger/mason_logger.dart';

class MigrateResult {
  final int blocksMoved;
  final bool sourceLineAdded;
  final bool alreadyMigrated;

  MigrateResult({
    required this.blocksMoved,
    required this.sourceLineAdded,
    required this.alreadyMigrated,
  });
}

class F {
  const F();

  static Logger logger = Logger();

  /// Override for testing — when set, [homeDir] returns this value.
  static String? homeDirOverride;

  /// Returns the user's home directory, cross-platform.
  static String homeDir() {
    if (homeDirOverride != null) return homeDirOverride!;
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? '';
    }
    return Platform.environment['HOME'] ?? '';
  }

  /// Returns the platform-specific PATH separator (`;` on Windows, `:` elsewhere).
  static String get envPathSeparator => Platform.isWindows ? ';' : ':';

  static Future<String> getPersistedPathFromRC({
    required RunCommandKey key,
    String? preferredPath,
  }) async {
    final home = homeDir();
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

  /// Returns the path to the dedicated env file (`~/.flutter_compile_env`).
  static String getEnvFilePath() {
    return '${homeDir()}/.${Constants.envFile}';
  }

  /// Idempotently ensures the shell RC has a `source` line for the env file.
  ///
  /// Also strips any legacy PATH blocks from the shell RC as migration.
  static Future<void> ensureSourceLineInShellRc() async {
    final configPath = getShellConfigPath();
    final configFile = File(configPath);

    var contents = '';
    if (await configFile.exists()) {
      contents = await configFile.readAsString();
    }

    var changed = false;

    // Migration: remove old PATH blocks from shell RC
    if (_flutterCompileBlockPattern.hasMatch(contents)) {
      contents = contents.replaceAll(_flutterCompileBlockPattern, '');
      changed = true;
    }
    if (_sdkManagerBlockPattern.hasMatch(contents)) {
      contents = contents.replaceAll(_sdkManagerBlockPattern, '');
      changed = true;
    }
    if (_depotToolsBlockPattern.hasMatch(contents)) {
      contents = contents.replaceAll(_depotToolsBlockPattern, '');
      changed = true;
    }

    // Migration: remove old double-dot source lines (~/..flutter_compile_env)
    if (Constants.legacyDoubleDotSourceLinePattern.hasMatch(contents)) {
      contents = contents.replaceAll(
        Constants.legacyDoubleDotSourceLinePattern,
        '',
      );
      changed = true;
    }

    // Add source line if not already present
    if (!Constants.platformSourceLinePattern.hasMatch(contents)) {
      contents += Constants.platformSourceLine;
      changed = true;
    }

    if (changed) {
      await configFile.parent.create(recursive: true);
      await configFile.writeAsString(contents);
    }
  }

  /// Migrates all flutter_compile PATH blocks from the shell RC to the
  /// dedicated env file (`~/.flutter_compile_env`).
  ///
  /// 1. Extracts all PATH blocks from the shell RC.
  /// 2. Appends them to the env file (skipping duplicates).
  /// 3. Strips them from the shell RC via [ensureSourceLineInShellRc].
  static Future<MigrateResult> migrateShellRcToEnvFile() async {
    final configPath = getShellConfigPath();
    final configFile = File(configPath);

    // If no shell RC exists, there is nothing to migrate.
    if (!await configFile.exists()) {
      // Still ensure the source line is present.
      await ensureSourceLineInShellRc();
      return MigrateResult(
        blocksMoved: 0,
        sourceLineAdded: true,
        alreadyMigrated: true,
      );
    }

    final rcContents = await configFile.readAsString();

    // Collect all matched blocks from the shell RC.
    final patterns = [
      _flutterCompileBlockPattern,
      _sdkManagerBlockPattern,
      _depotToolsBlockPattern,
    ];

    final extractedBlocks = <String>[];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(rcContents)) {
        extractedBlocks.add(match.group(0)!);
      }
    }

    if (extractedBlocks.isEmpty) {
      // No legacy blocks found — just ensure source line.
      await ensureSourceLineInShellRc();
      final hadSourceLine =
          Constants.platformSourceLinePattern.hasMatch(rcContents);
      return MigrateResult(
        blocksMoved: 0,
        sourceLineAdded: !hadSourceLine,
        alreadyMigrated: true,
      );
    }

    // Read (or start) the env file.
    final envPath = getEnvFilePath();
    final envFile = File(envPath);
    var envContents = '';
    if (await envFile.exists()) {
      envContents = await envFile.readAsString();
    }

    // Append only blocks not already present in the env file.
    var blocksMoved = 0;
    for (final block in extractedBlocks) {
      if (!envContents.contains(block.trim())) {
        envContents += block;
        blocksMoved++;
      }
    }

    // Write the env file.
    await envFile.parent.create(recursive: true);
    await envFile.writeAsString(envContents);

    // Strip blocks from the shell RC and add source line.
    final hadSourceLine =
        Constants.platformSourceLinePattern.hasMatch(rcContents);
    await ensureSourceLineInShellRc();

    // Rewrite the SDK manager block with the new guarded template so
    // existing users get the FLUTTER_COMPILE_SDK support via `fcp migrate`.
    final globalVersion = await readGlobalSdkVersion();
    if (globalVersion != null) {
      final sdkPath = getSdkPath(globalVersion);
      if (sdkPath != null && isFlutterSdk(sdkPath)) {
        await updateShellSdkPath(sdkPath);
      }
    }

    return MigrateResult(
      blocksMoved: blocksMoved,
      sourceLineAdded: !hadSourceLine,
      alreadyMigrated: false,
    );
  }

  /// Returns the path to the user's shell config file.
  ///
  /// On Windows, returns the PowerShell profile path.
  /// On Unix, returns ~/.zshrc, ~/.bashrc, or ~/.profile.
  static String getShellConfigPath() {
    final home = homeDir();
    if (Platform.isWindows) {
      // PowerShell profile: Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1
      final docs = Platform.environment['USERPROFILE'] ?? home;
      return '$docs\\Documents\\WindowsPowerShell\\Microsoft.PowerShell_profile.ps1';
    }
    final shell = Platform.environment['SHELL'] ?? '';
    final shellConfig = shell.contains('bash')
        ? '.bashrc'
        : shell.contains('zsh')
            ? '.zshrc'
            : '.profile';
    return '$home/$shellConfig';
  }

  static Future<String> getHostCpuArch() async {
    if (Platform.isWindows) {
      final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? 'AMD64';
      return arch == 'ARM64' ? 'arm64' : 'x86_64';
    }
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
    } else if (os == 'windows') {
      logger.info(
        'On Windows, install Android platform tools manually or via Android Studio.',
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
      final lookupCommand = Platform.isWindows ? 'where' : 'which';
      final result = await Process.run(lookupCommand, [command]);
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

  /// Regex that matches the flutter_compile setup CLI PATH block
  /// regardless of the actual path content between the marker comments.
  static final _flutterCompileBlockPattern = RegExp(
    r'\n?# >>> Added by flutter_compile setup CLI >>>'
    r'[\s\S]*?'
    r'# <<< Added by flutter_compile setup CLI <<<\n?',
  );

  /// Regex that matches the SDK manager PATH block.
  static final _sdkManagerBlockPattern = RegExp(
    r'\n?# >>> Added by flutter_compile SDK manager >>>'
    r'[\s\S]*?'
    r'# <<< Added by flutter_compile SDK manager <<<\n?',
  );

  /// Regex that matches the depot_tools PATH block.
  static final _depotToolsBlockPattern = RegExp(
    r'\n?# >>> Added by flutter_compile setup CLI \(depot_tools\) >>>'
    r'[\s\S]*?'
    r'# <<< Added by flutter_compile setup CLI \(depot_tools\) <<<\n?',
  );

  static Future<void> switchFlutterEnvironment({FlutterMode? mode}) async {
    try {
      await ensureSourceLineInShellRc();

      final flutterCompilePath = await F.getPersistedPathFromRC(
        key: RunCommandKey.flutterCompile,
      );

      final envPath = getEnvFilePath();
      final envFile = File(envPath);
      var contents = '';
      if (await envFile.exists()) {
        contents = await envFile.readAsString();
      }

      final flutterCompilePATHExport = Constants
          .platformFlutterCompilePATHExport
          .replaceAll('{{path}}', flutterCompilePath);

      final isUsingCompiledVersion =
          _flutterCompileBlockPattern.hasMatch(contents);

      if (mode == FlutterMode.compiled && !isUsingCompiledVersion) {
        contents += flutterCompilePATHExport;
        await envFile.parent.create(recursive: true);
        await envFile.writeAsString(contents);
        logger.success(Constants.flutterCompileSwitchedToCompiled);
      } else if (mode == FlutterMode.normal && isUsingCompiledVersion) {
        contents = contents.replaceAll(_flutterCompileBlockPattern, '');
        await envFile.writeAsString(contents);
        logger.success(Constants.flutterCompileSwitchedToNormal);
      } else if (mode == null) {
        contents = isUsingCompiledVersion
            ? contents.replaceAll(_flutterCompileBlockPattern, '')
            : contents + flutterCompilePATHExport;
        await envFile.parent.create(recursive: true);
        await envFile.writeAsString(contents);
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

      logger.info(Constants.platformRestartShell);
    } catch (e) {
      final message = 'Error: $e';
      logger.err(message);
      throw FlutterCompileException(message, exitCode: ExitCode.software.code);
    }
  }

  /// Returns true if [path] is a directory containing a valid `.git/HEAD` file.
  static bool isValidGitRepo(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return false;
    final headFile = File('$path/.git/HEAD');
    return headFile.existsSync();
  }

  static Future<void> cloneRepository(
    String url,
    String directory, {
    bool force = false,
  }) async {
    final dir = Directory(directory);
    if (dir.existsSync()) {
      if (force) {
        logger.info('Removing existing directory and re-cloning...');
        dir.deleteSync(recursive: true);
      } else if (!isValidGitRepo(directory)) {
        logger.info(
          'Directory $directory exists but is not a valid git repo. '
          'Cleaning up and re-cloning...',
        );
        dir.deleteSync(recursive: true);
      } else {
        logger.info('Directory $directory already exists. Skipping clone.');
        return;
      }
    }
    try {
      await runCommand(
        'git',
        ['clone', url, directory],
      );
    } catch (e) {
      // Clean up partial clone on failure
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      rethrow;
    }
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
        final colonIndex = line.indexOf(':');
        if (colonIndex != -1) {
          keyValuePairs[line.substring(0, colonIndex)] =
              line.substring(colonIndex + 1);
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
        final colonIndex = line.indexOf(':');
        if (colonIndex != -1 && line.substring(0, colonIndex) == key) {
          return line.substring(colonIndex + 1);
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
    final home = homeDir();
    return '$home${Constants.sdkVersionsPath}/$version';
  }

  /// Resolves the actual filesystem path for an SDK [version].
  ///
  /// First tries the canonical path (`sdkVersionPath(version)`), then falls
  /// back to scanning the versions directory for a directory whose trimmed
  /// name matches. This handles directories created with trailing whitespace.
  static String? getSdkPath(String version) {
    final trimmed = version.trim();
    final canonical = sdkVersionPath(trimmed);
    if (Directory(canonical).existsSync()) return canonical;

    // Fallback: scan versions dir for a directory whose trimmed name matches.
    // When found, rename the directory to the canonical (trimmed) name so
    // subsequent lookups hit the fast path and no trailing whitespace leaks
    // into shell config files.
    final vDir = Directory('${homeDir()}${Constants.sdkVersionsPath}');
    if (vDir.existsSync()) {
      for (final entry in vDir.listSync()) {
        if (entry is Directory) {
          final dirName = entry.path.split(Platform.pathSeparator).last;
          if (dirName.trim() == trimmed && dirName != trimmed) {
            try {
              entry.renameSync(canonical);
            } catch (_) {
              return entry.path; // rename failed — return raw path
            }
            return canonical;
          }
        }
      }
    }

    return null;
  }

  /// Returns true if [version] is installed as a usable Flutter SDK.
  ///
  /// Checks for the `bin/flutter` executable rather than `.git/HEAD`
  /// so that SDKs installed from release archives (no `.git`) still work.
  /// Uses [getSdkPath] to handle directories with trailing whitespace.
  static bool isSdkInstalled(String version) {
    final sdkPath = getSdkPath(version);
    return sdkPath != null && isFlutterSdk(sdkPath);
  }

  /// Returns true if [path] contains a Flutter SDK (has `bin/flutter`).
  static bool isFlutterSdk(String path) {
    final flutter = Platform.isWindows
        ? File('$path/bin/flutter.bat')
        : File('$path/bin/flutter');
    return flutter.existsSync();
  }

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
    final home = homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');
    return readValueForKeyFromRcConfig(
      rcConfigFile,
      Constants.globalSdkVersionKey,
    );
  }

  static Future<String?> resolveActiveSdkVersion() async {
    return await readProjectSdkVersion() ?? await readGlobalSdkVersion();
  }

  /// Update the env file with the SDK manager PATH block.
  ///
  /// Replaces any existing `flutter_compile SDK manager` block and appends
  /// a new one pointing to [sdkPath]. Also ensures the shell RC has the
  /// source line.
  static Future<void> updateShellSdkPath(String sdkPath) async {
    if (!isFlutterSdk(sdkPath)) {
      logger.err(
        'Refusing to update shell config: "$sdkPath" is not a valid Flutter SDK.',
      );
      return;
    }

    await ensureSourceLineInShellRc();

    final pubCachePath = sdkPubCachePath(sdkPath);
    final envPath = getEnvFilePath();
    final envFile = File(envPath);

    var contents = '';
    if (await envFile.exists()) {
      contents = await envFile.readAsString();
    }

    // Remove any existing SDK manager block
    contents = contents.replaceAll(_sdkManagerBlockPattern, '');

    // Append new SDK manager block
    final pathExport = Constants.platformSdkPATHExport
        .replaceAll('{{path}}', sdkPath)
        .replaceAll('{{pub_cache_path}}', pubCachePath);
    contents += pathExport;

    await envFile.parent.create(recursive: true);
    await envFile.writeAsString(contents);
  }

  /// Create or update the `default` symlink to point to [sdkPath].
  ///
  /// If a real directory (not a symlink) named `default` already exists in
  /// the versions folder, this is a no-op to avoid deleting a user's SDK.
  static Future<void> updateDefaultSdkLink(String sdkPath) async {
    final linkPath =
        '${homeDir()}${Constants.sdkVersionsPath}/${Constants.defaultSdkLink}';
    final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      return; // real dir — don't touch
    }
    if (type == FileSystemEntityType.link) Link(linkPath).deleteSync();
    await Link(linkPath).create(sdkPath);
  }

  /// Remove the `default` symlink if it exists.
  static Future<void> removeDefaultSdkLink() async {
    final linkPath =
        '${homeDir()}${Constants.sdkVersionsPath}/${Constants.defaultSdkLink}';
    final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
    if (type == FileSystemEntityType.link) Link(linkPath).deleteSync();
  }

  /// Remove the SDK manager PATH block from the env file.
  ///
  /// Also strips any legacy blocks from the shell RC as migration.
  static Future<void> removeShellSdkPath() async {
    // Clean env file
    final envPath = getEnvFilePath();
    final envFile = File(envPath);
    if (await envFile.exists()) {
      var contents = await envFile.readAsString();
      contents = contents.replaceAll(_sdkManagerBlockPattern, '');
      await envFile.writeAsString(contents);
    }

    // Migration: also strip legacy block from shell RC
    final configPath = getShellConfigPath();
    final configFile = File(configPath);
    if (await configFile.exists()) {
      var contents = await configFile.readAsString();
      if (_sdkManagerBlockPattern.hasMatch(contents)) {
        contents = contents.replaceAll(_sdkManagerBlockPattern, '');
        await configFile.writeAsString(contents);
      }
    }
  }
}
