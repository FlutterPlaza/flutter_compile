import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:flutter_compile/src/commands/commands.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/pub_cache_busting_client.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:pub_updater/pub_updater.dart';

const executableName = 'flutter_compile';
const packageName = 'flutter_compile';
const description =
    'A Dart CLI to simplify the setting up your framework development environment, which describes and automates the steps you need to configure your computer to work on Flutter&#x27;s Framework';

/// {@template flutter_compile_command_runner}
/// A [CommandRunner] for the CLI.
///
/// ```bash
/// $ flutter_compile --version
/// ```
/// {@endtemplate}
class FlutterCompileCommandRunner extends CompletionCommandRunner<int> {
  /// {@macro flutter_compile_command_runner}
  FlutterCompileCommandRunner({
    Logger? logger,
    PubUpdater? pubUpdater,
  })  : _logger = logger ?? Logger(),
        // Wrap PubUpdater's HTTP client with a cache-busting shim so that
        // back-to-back version checks (e.g. `update` then `--version`)
        // can't disagree because pub.dev's CDN served one a stale edge
        // node. See pub_cache_busting_client.dart and issue #17.
        _pubUpdater = pubUpdater ?? PubUpdater(PubCacheBustingClient()),
        super(executableName, description) {
    // Add root options and flags
    argParser
      ..addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: 'Print the current version.',
      )
      ..addFlag(
        'verbose',
        help: 'Noisy logging, including all shell commands executed.',
      );

    // Add sub commands
    addCommand(BuildCommand(_logger));
    addCommand(CleanCommand(_logger));
    addCommand(CodePushCommand(_logger));
    addCommand(ConfigCommand(_logger));
    addCommand(DoctorCommand(_logger));
    addCommand(FlutterSwitchCommand(_logger));
    addCommand(InstallCommand(_logger));
    addCommand(MigrateCommand(_logger));
    addCommand(RunCommand(_logger));
    addCommand(SdkCommand(_logger));
    addCommand(StatusCommand(_logger));
    addCommand(SyncCommand(_logger));
    addCommand(TestCommand(_logger));
    addCommand(DaemonCommand(_logger));
    addCommand(UiCommand(_logger));
    addCommand(UninstallCommand(_logger));
    addCommand(UpdateCommand(logger: _logger, pubUpdater: _pubUpdater));
  }

  @override
  void printUsage() => _logger.info(usage);

  final Logger _logger;
  final PubUpdater _pubUpdater;

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final topLevelResults = parse(args);
      if (topLevelResults['verbose'] == true) {
        _logger.level = Level.verbose;
      }
      return await runCommand(topLevelResults) ?? ExitCode.success.code;
    } on FlutterCompileException catch (e) {
      return e.exitCode ?? ExitCode.software.code;
    } on FormatException catch (e, stackTrace) {
      // On format errors, show the commands error message, root usage and
      // exit with an error code
      _logger
        ..err(e.message)
        ..err('$stackTrace')
        ..info('')
        ..info(usage);
      return ExitCode.usage.code;
    } on UsageException catch (e) {
      // On usage errors, show the commands usage message and
      // exit with an error code
      _logger
        ..err(e.message)
        ..info('')
        ..info(e.usage);
      return ExitCode.usage.code;
    }
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Fast track completion command
    if (topLevelResults.command?.name == 'completion') {
      await super.runCommand(topLevelResults);
      return ExitCode.success.code;
    }

    // Verbose logs
    _logger
      ..detail('Argument information:')
      ..detail('  Top level options:');
    for (final option in topLevelResults.options) {
      if (topLevelResults.wasParsed(option)) {
        _logger.detail('  - $option: ${topLevelResults[option]}');
      }
    }
    if (topLevelResults.command != null) {
      final commandResult = topLevelResults.command!;
      _logger
        ..detail('  Command: ${commandResult.name}')
        ..detail('    Command options:');
      for (final option in commandResult.options) {
        if (commandResult.wasParsed(option)) {
          _logger.detail('    - $option: ${commandResult[option]}');
        }
      }
    }

    // Run the command or show version
    final int? exitCode;
    if (topLevelResults['version'] == true) {
      _logger.info(packageVersion);
      exitCode = ExitCode.success.code;
    } else {
      exitCode = await super.runCommand(topLevelResults);
    }

    // Check for updates
    if (topLevelResults.command?.name != UpdateCommand.commandName) {
      await _checkForUpdates();
    }

    return exitCode;
  }

  /// Checks if the current version (set by the build runner on the
  /// version.dart file) is the most recent one. If not, show a prompt to the
  /// user.
  ///
  /// Skips the "Update available!" banner when the running version is
  /// newer than (or equal to) what pub.dev reports as latest — e.g.
  /// when the user is running a pre-release build installed from
  /// `dart pub global activate --source git`, or when they're running
  /// a version that hit the pub.dev daily-publish rate limit and is
  /// not yet on the index.
  Future<void> _checkForUpdates() async {
    try {
      final latestVersion = await _pubUpdater.getLatestVersion(packageName);
      if (_compareSemver(packageVersion, latestVersion) >= 0) {
        // Running version is same as or newer than pub.dev's latest.
        // No banner.
        return;
      }
      _logger
        ..info('')
        ..info(
          '''
${lightYellow.wrap('Update available!')} ${lightCyan.wrap(packageVersion)} \u2192 ${lightCyan.wrap(latestVersion)}
Run ${lightCyan.wrap('$executableName update')} to update''',
        );
    } catch (_) {}
  }

  /// Compare two semver-like version strings. Returns a negative
  /// number if [a] < [b], zero if equal, positive if [a] > [b].
  /// Handles `major.minor.patch` components and ignores any
  /// pre-release / build metadata suffixes (so `0.19.13-dev` is
  /// treated as `0.19.13`).
  static int _compareSemver(String a, String b) {
    List<int> parse(String v) {
      // Strip anything after `-` or `+` (pre-release / build metadata).
      final main = v.split(RegExp('[-+]')).first;
      final parts = main.split('.');
      final out = <int>[];
      for (final p in parts) {
        out.add(int.tryParse(p) ?? 0);
      }
      while (out.length < 3) {
        out.add(0);
      }
      return out;
    }

    final pa = parse(a);
    final pb = parse(b);
    for (var i = 0; i < 3; i++) {
      final d = pa[i].compareTo(pb[i]);
      if (d != 0) return d;
    }
    return 0;
  }
}
