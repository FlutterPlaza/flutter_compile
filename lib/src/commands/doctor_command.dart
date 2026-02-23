import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

Future<List<Map<String, dynamic>>> gatherDoctorChecks() async {
  final checks = <Map<String, dynamic>>[];

  // Check required tools
  final tools = ['git', 'python3', 'dart', 'flutter'];
  for (final tool in tools) {
    final available = await F.isCommandAvailable(tool);
    checks.add({
      'name': tool,
      'category': 'tools',
      'status': available ? 'ok' : 'missing',
    });
  }

  // Check engine-related tools
  final gclientAvailable = await _isGclientAvailable();
  checks.add({
    'name': 'gclient',
    'category': 'engine_tools',
    'status': gclientAvailable ? 'ok' : 'missing',
  });

  final ninjaAvailable = await F.isCommandAvailable('ninja');
  checks.add({
    'name': 'ninja',
    'category': 'engine_tools',
    'status': ninjaAvailable ? 'ok' : 'missing',
  });

  // Check Xcode (macOS only)
  if (Platform.isMacOS) {
    final xcodeAvailable = await F.isCommandAvailable('xcodebuild');
    checks.add({
      'name': 'xcode',
      'category': 'engine_tools',
      'status': xcodeAvailable ? 'ok' : 'missing',
    });
  }

  // Check Visual Studio (Windows only)
  if (Platform.isWindows) {
    final vsAvailable = await F.isCommandAvailable('cl');
    checks.add({
      'name': 'visual_studio',
      'category': 'engine_tools',
      'status': vsAvailable ? 'ok' : 'missing',
    });
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
  } else {
    checks.add({
      'name': '.flutter_compilerc',
      'category': 'config',
      'status': 'not_found',
    });
  }

  // Check contributor environments
  await _checkEnvironmentForGather(
    label: 'Flutter contributor environment',
    configKey: RunCommandKey.flutterCompile.key,
    defaultPath: '$home${Constants.flutterCompileInstallPath}',
    checks: checks,
  );

  await _checkEnvironmentForGather(
    label: 'DevTools contributor environment',
    configKey: RunCommandKey.devTools.key,
    defaultPath: '$home${Constants.devToolsInstallPath}',
    checks: checks,
  );

  await _checkEnvironmentForGather(
    label: 'Engine contributor environment',
    configKey: RunCommandKey.engine.key,
    defaultPath: '$home${Constants.engineInstallPath}',
    checks: checks,
  );

  return checks;
}

/// Check for gclient on PATH, then probe known depot_tools locations.
Future<bool> _isGclientAvailable() async {
  if (await F.isCommandAvailable('gclient')) return true;

  final home = F.homeDir();
  final bin = Platform.isWindows ? 'gclient.bat' : 'gclient';

  // Check depot_tools_path from .flutter_compilerc
  final rcFile = File('$home/.flutter_compilerc');
  final depotPath =
      await F.readValueForKeyFromRcConfig(rcFile, RunCommandKey.depotTools.key);
  if (depotPath != null && depotPath.isNotEmpty) {
    final gclient = File('$depotPath/$bin');
    if (await gclient.exists()) return true;
  }

  // Check default install location
  final defaultGclient = File('$home${Constants.depotToolsInstallPath}/$bin');
  if (await defaultGclient.exists()) return true;

  return false;
}

Future<void> _checkEnvironmentForGather({
  required String label,
  required String configKey,
  required String defaultPath,
  required List<Map<String, dynamic>> checks,
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
    return;
  }

  envPath = envPath.isEmpty ? defaultPath : envPath;

  // The rc config may store the bin path (e.g. ~/flutter_compile/flutter/bin)
  // instead of the repo root. Strip trailing /bin to get the actual git repo.
  final sep = Platform.isWindows ? r'\' : '/';
  if (envPath.endsWith('${sep}bin')) {
    envPath = envPath.substring(0, envPath.length - 4);
  }

  final dir = Directory(envPath);
  if (!await dir.exists()) {
    checks.add({
      'name': label,
      'category': 'environments',
      'status': 'not_found',
      'path': envPath,
    });
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
      }
    } else {
      checks.add({
        'name': label,
        'category': 'environments',
        'status': 'not_git_repo',
        'path': envPath,
      });
    }
  } catch (e) {
    checks.add({
      'name': label,
      'category': 'environments',
      'status': 'error',
      'path': envPath,
      'error': e.toString(),
    });
  }
}

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
    final checks = await gatherDoctorChecks();

    if (asJson) {
      _logger.info(json.encode(checks));
      return ExitCode.success.code;
    }

    _logger.info('Flutter Compile Doctor\n');

    for (final check in checks) {
      final name = check['name'] as String;
      final category = check['category'] as String;
      final status = check['status'] as String;

      if (category == 'tools') {
        _logger.info(status == 'ok'
            ? '  [+] $name is installed'
            : '  [X] $name is NOT installed');
      } else if (category == 'engine_tools') {
        final displayName = switch (name) {
          'gclient' => 'depot_tools (gclient)',
          'xcode' => 'Xcode',
          'visual_studio' => 'Visual Studio (cl.exe)',
          _ => name,
        };
        _logger.info(status == 'ok'
            ? '  [+] $displayName is installed'
            : '  [X] $displayName is NOT installed');
      } else if (category == 'config') {
        if (status == 'ok') {
          _logger.info('  [+] .flutter_compilerc is valid');
        } else if (status == 'invalid') {
          _logger.info('  [X] .flutter_compilerc has invalid format');
        } else {
          _logger.info('  [-] .flutter_compilerc not found');
        }
      } else if (category == 'environments') {
        final path = check['path'] as String?;
        switch (status) {
          case 'not_configured':
            _logger.info('  [-] $name: not configured');
          case 'not_found':
            _logger.info('  [X] $name: directory not found ($path)');
          case 'ok':
            _logger.info('  [+] $name: installed');
          case 'missing_remotes':
            final missing = (check['missing_remotes'] as List).join(', ');
            _logger.info('  [X] $name: missing remotes ($missing)');
          case 'not_git_repo':
            _logger.info('  [X] $name: not a git repository');
          case 'error':
            final error = check['error'];
            _logger.info('  [X] $name: error checking ($error)');
          default:
            _logger.info('  [?] $name: $status');
        }
      }
    }

    return ExitCode.success.code;
  }
}
