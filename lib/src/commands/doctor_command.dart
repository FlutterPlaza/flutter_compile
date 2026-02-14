import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class DoctorCommand extends Command<int> {
  DoctorCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'doctor';

  @override
  final String description =
      'Check the health of your Flutter contributor environment';

  @override
  Future<int> run() async {
    _logger.info('Flutter Compile Doctor\n');

    // Check required tools
    final tools = ['git', 'python3', 'dart', 'flutter'];
    for (final tool in tools) {
      final available = await F.isCommandAvailable(tool);
      if (available) {
        _logger.info('  [+] $tool is installed');
      } else {
        _logger.info('  [X] $tool is NOT installed');
      }
    }

    // Check .flutter_compilerc config file
    final home = Platform.environment['HOME'] ?? '';
    final rcFile = File('$home/.flutter_compilerc');
    if (await rcFile.exists()) {
      final lines = await rcFile.readAsLines();
      final valid = lines.every((line) {
        if (line.trim().isEmpty) return true;
        return line.contains(':') && line.split(':').length == 2;
      });
      if (valid) {
        _logger.info('  [+] .flutter_compilerc is valid');
      } else {
        _logger.info('  [X] .flutter_compilerc has invalid format');
      }
    } else {
      _logger.info('  [-] .flutter_compilerc not found');
    }

    // Check Flutter contributor environment
    await _checkEnvironment(
      label: 'Flutter contributor environment',
      configKey: RunCommandKey.flutterCompile.key,
      defaultPath: '$home${Constants.flutterCompileInstallPath}',
    );

    // Check DevTools contributor environment
    await _checkEnvironment(
      label: 'DevTools contributor environment',
      configKey: RunCommandKey.devTools.key,
      defaultPath: '$home${Constants.devToolsInstallPath}',
    );

    return ExitCode.success.code;
  }

  Future<void> _checkEnvironment({
    required String label,
    required String configKey,
    required String defaultPath,
  }) async {
    final home = Platform.environment['HOME'] ?? '';
    final rcFile = File('$home/.flutter_compilerc');

    var envPath = await F.readValueForKeyFromRcConfig(rcFile, configKey);
    if (envPath == null) {
      _logger.info('  [-] $label: not configured');
      return;
    }

    envPath = envPath.isEmpty ? defaultPath : envPath;
    final dir = Directory(envPath);
    if (!await dir.exists()) {
      _logger.info('  [X] $label: directory not found ($envPath)');
      return;
    }

    // Check for upstream and origin git remotes
    try {
      final result = await Process.run(
        'git',
        ['remote'],
        workingDirectory: envPath,
      );
      if (result.exitCode == 0) {
        final remotes = (result.stdout as String).trim().split('\n');
        final hasUpstream = remotes.contains('upstream');
        final hasOrigin = remotes.contains('origin');
        if (hasUpstream && hasOrigin) {
          _logger.info('  [+] $label: installed');
        } else {
          final missing = <String>[];
          if (!hasUpstream) missing.add('upstream');
          if (!hasOrigin) missing.add('origin');
          _logger.info(
            '  [X] $label: missing remotes (${missing.join(', ')})',
          );
        }
      } else {
        _logger.info('  [X] $label: not a git repository');
      }
    } catch (e) {
      _logger.info('  [X] $label: error checking ($e)');
    }
  }
}
