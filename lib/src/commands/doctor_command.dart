import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class DoctorCommand extends Command<int> {
  DoctorCommand(this._logger) {
    argParser.addFlag(
      'json',
      help: 'Output as JSON.',
      negatable: false,
    );
  }

  final Logger _logger;

  @override
  final String name = 'doctor';

  @override
  final List<String> aliases = ['dr'];

  @override
  final String description =
      'Check the health of your Flutter contributor environment';

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;
    final checks = <Map<String, dynamic>>[];

    if (!asJson) _logger.info('Flutter Compile Doctor\n');

    // Check required tools
    final tools = ['git', 'python3', 'dart', 'flutter'];
    for (final tool in tools) {
      final available = await F.isCommandAvailable(tool);
      checks.add({
        'name': tool,
        'category': 'tools',
        'status': available ? 'ok' : 'missing',
      });
      if (!asJson) {
        if (available) {
          _logger.info('  [+] $tool is installed');
        } else {
          _logger.info('  [X] $tool is NOT installed');
        }
      }
    }

    // Check engine-related tools
    final gclientAvailable = await F.isCommandAvailable('gclient');
    checks.add({
      'name': 'gclient',
      'category': 'engine_tools',
      'status': gclientAvailable ? 'ok' : 'missing',
    });
    if (!asJson) {
      _logger.info(gclientAvailable
          ? '  [+] depot_tools (gclient) is installed'
          : '  [X] depot_tools (gclient) is NOT installed');
    }

    final ninjaAvailable = await F.isCommandAvailable('ninja');
    checks.add({
      'name': 'ninja',
      'category': 'engine_tools',
      'status': ninjaAvailable ? 'ok' : 'missing',
    });
    if (!asJson) {
      _logger.info(ninjaAvailable
          ? '  [+] ninja is installed'
          : '  [X] ninja is NOT installed');
    }

    // Check Xcode (macOS only)
    if (Platform.isMacOS) {
      final xcodeAvailable = await F.isCommandAvailable('xcodebuild');
      checks.add({
        'name': 'xcode',
        'category': 'engine_tools',
        'status': xcodeAvailable ? 'ok' : 'missing',
      });
      if (!asJson) {
        _logger.info(xcodeAvailable
            ? '  [+] Xcode is installed'
            : '  [X] Xcode is NOT installed');
      }
    }

    // Check Visual Studio (Windows only)
    if (Platform.isWindows) {
      final vsAvailable = await F.isCommandAvailable('cl');
      checks.add({
        'name': 'visual_studio',
        'category': 'engine_tools',
        'status': vsAvailable ? 'ok' : 'missing',
      });
      if (!asJson) {
        _logger.info(vsAvailable
            ? '  [+] Visual Studio (cl.exe) is installed'
            : '  [X] Visual Studio (cl.exe) is NOT installed');
      }
    }

    // Check .flutter_compilerc config file
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');
    if (await rcFile.exists()) {
      final lines = await rcFile.readAsLines();
      final valid = lines.every((line) {
        if (line.trim().isEmpty) return true;
        return line.contains(':') && line.split(':').length == 2;
      });
      checks.add({
        'name': '.flutter_compilerc',
        'category': 'config',
        'status': valid ? 'ok' : 'invalid',
      });
      if (!asJson) {
        if (valid) {
          _logger.info('  [+] .flutter_compilerc is valid');
        } else {
          _logger.info('  [X] .flutter_compilerc has invalid format');
        }
      }
    } else {
      checks.add({
        'name': '.flutter_compilerc',
        'category': 'config',
        'status': 'not_found',
      });
      if (!asJson) {
        _logger.info('  [-] .flutter_compilerc not found');
      }
    }

    // Check contributor environments
    await _checkEnvironment(
      label: 'Flutter contributor environment',
      configKey: RunCommandKey.flutterCompile.key,
      defaultPath: '$home${Constants.flutterCompileInstallPath}',
      checks: checks,
      asJson: asJson,
    );

    await _checkEnvironment(
      label: 'DevTools contributor environment',
      configKey: RunCommandKey.devTools.key,
      defaultPath: '$home${Constants.devToolsInstallPath}',
      checks: checks,
      asJson: asJson,
    );

    await _checkEnvironment(
      label: 'Engine contributor environment',
      configKey: RunCommandKey.engine.key,
      defaultPath: '$home${Constants.engineInstallPath}',
      gitSubpath: 'src/flutter',
      checks: checks,
      asJson: asJson,
    );

    if (asJson) {
      _logger.info(json.encode(checks));
    }

    return ExitCode.success.code;
  }

  Future<void> _checkEnvironment({
    required String label,
    required String configKey,
    required String defaultPath,
    required List<Map<String, dynamic>> checks,
    required bool asJson,
    String? gitSubpath,
  }) async {
    final home = F.homeDir();
    final rcFile = File('$home/.flutter_compilerc');

    var envPath = await F.readValueForKeyFromRcConfig(rcFile, configKey);
    if (envPath == null) {
      checks.add({
        'name': label,
        'category': 'environments',
        'status': 'not_configured',
      });
      if (!asJson) _logger.info('  [-] $label: not configured');
      return;
    }

    envPath = envPath.isEmpty ? defaultPath : envPath;
    final dir = Directory(envPath);
    if (!await dir.exists()) {
      checks.add({
        'name': label,
        'category': 'environments',
        'status': 'not_found',
        'path': envPath,
      });
      if (!asJson) {
        _logger.info('  [X] $label: directory not found ($envPath)');
      }
      return;
    }

    // For engine, git remotes are in src/flutter subdirectory
    final gitDir = gitSubpath != null ? '$envPath/$gitSubpath' : envPath;

    // Check for upstream and origin git remotes
    try {
      final result = await Process.run(
        'git',
        ['remote'],
        workingDirectory: gitDir,
      );
      if (result.exitCode == 0) {
        final remotes = (result.stdout as String).trim().split('\n');
        final hasUpstream = remotes.contains('upstream');
        final hasOrigin = remotes.contains('origin');
        if (hasUpstream && hasOrigin) {
          checks.add({
            'name': label,
            'category': 'environments',
            'status': 'ok',
            'path': envPath,
          });
          if (!asJson) _logger.info('  [+] $label: installed');
        } else {
          final missing = <String>[];
          if (!hasUpstream) missing.add('upstream');
          if (!hasOrigin) missing.add('origin');
          checks.add({
            'name': label,
            'category': 'environments',
            'status': 'missing_remotes',
            'path': envPath,
            'missing_remotes': missing,
          });
          if (!asJson) {
            _logger.info(
              '  [X] $label: missing remotes (${missing.join(', ')})',
            );
          }
        }
      } else {
        checks.add({
          'name': label,
          'category': 'environments',
          'status': 'not_git_repo',
          'path': envPath,
        });
        if (!asJson) _logger.info('  [X] $label: not a git repository');
      }
    } catch (e) {
      checks.add({
        'name': label,
        'category': 'environments',
        'status': 'error',
        'path': envPath,
        'error': e.toString(),
      });
      if (!asJson) _logger.info('  [X] $label: error checking ($e)');
    }
  }
}
