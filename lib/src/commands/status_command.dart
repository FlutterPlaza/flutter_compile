import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

Future<Map<String, dynamic>> gatherStatus() async {
  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');
  final enginePath = await F.readValueForKeyFromRcConfig(
    rcConfigFile,
    RunCommandKey.engine.key,
  );

  if (enginePath == null || enginePath.isEmpty) {
    return {'configured': false};
  }

  final srcDir = '$enginePath/src';
  final srcExists = await Directory(srcDir).exists();
  final hostArch = await F.getHostCpuArch();
  final hasPubspec = await File('pubspec.yaml').exists();

  // Scan for available builds
  final builds = <Map<String, String>>[];
  if (srcExists) {
    final outDir = Directory('$srcDir/out');
    if (await outDir.exists()) {
      await for (final entity in outDir.list()) {
        if (entity is Directory) {
          final name = entity.path.split('/').last;
          String size;
          if (Platform.isWindows) {
            final sizeResult = await Process.run('powershell', [
              '-Command',
              '(Get-ChildItem -Recurse -File "${entity.path}" '
                  '| Measure-Object -Property Length -Sum).Sum / 1MB '
                  '| ForEach-Object { "{0:N1}M" -f \$_ }',
            ]);
            size = (sizeResult.stdout as String).trim();
          } else {
            final sizeResult = await Process.run('du', ['-sh', entity.path]);
            size = (sizeResult.stdout as String).split('\t').first.trim();
          }
          builds.add({'name': name, 'size': size});
        }
      }
    }
  }

  return {
    'configured': true,
    'engine_path': enginePath,
    'source_dir': srcDir,
    'source_exists': srcExists,
    'host_cpu': hostArch,
    'builds': builds,
    'flutter_project': hasPubspec,
  };
}

class StatusCommand extends Command<int> {
  StatusCommand(this._logger) {
    argParser.addFlag(
      'json',
      help: 'Output as JSON.',
      negatable: false,
    );
  }

  final Logger _logger;

  @override
  final String name = 'status';

  @override
  final List<String> aliases = ['st'];

  @override
  final String description = 'Show engine configuration and available builds.';

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;
    final status = await gatherStatus();

    if (status['configured'] != true) {
      if (asJson) {
        _logger.info(json.encode(status));
      } else {
        _logger.info(
          'Engine not configured. '
          'Run `flutter_compile install engine` first.',
        );
      }
      return ExitCode.success.code;
    }

    if (asJson) {
      _logger.info(json.encode(status));
      return ExitCode.success.code;
    }

    final enginePath = status['engine_path'] as String;
    final srcDir = status['source_dir'] as String;
    final srcExists = status['source_exists'] as bool;
    final hostArch = status['host_cpu'] as String;
    final builds = status['builds'] as List<Map<String, String>>;
    final hasPubspec = status['flutter_project'] as bool;

    final srcStatus = srcExists ? 'OK' : 'NOT FOUND';

    _logger.info('Engine path: $enginePath');
    _logger.info('Source dir:  $srcDir [$srcStatus]');
    _logger.info('Host CPU:    $hostArch');

    if (srcExists) {
      _logger.info('');
      if (builds.isEmpty) {
        _logger.info('Available builds: (none)');
      } else {
        _logger.info('Available builds:');
        for (final b in builds) {
          final name = b['name']!;
          final size = b['size']!;
          _logger.info(
            '  $name${' ' * (30 - name.length).clamp(0, 30)}$size',
          );
        }
      }
    }

    _logger.info('');
    _logger.info(
      'Flutter project: ${hasPubspec ? 'yes (pubspec.yaml found)' : 'no'}',
    );

    return ExitCode.success.code;
  }
}
