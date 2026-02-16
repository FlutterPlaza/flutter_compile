import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class StatusCommand extends Command<int> {
  StatusCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'status';

  @override
  final List<String> aliases = ['st'];

  @override
  final String description = 'Show engine configuration and available builds.';

  @override
  Future<int> run() async {
    // Read engine path from .flutter_compilerc
    final home = Platform.environment['HOME'] ?? '';
    final rcConfigFile = File('$home/.flutter_compilerc');
    final enginePath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.engine.key,
    );

    if (enginePath == null || enginePath.isEmpty) {
      _logger.info(
        'Engine not configured. '
        'Run `flutter_compile install engine` first.',
      );
      return ExitCode.success.code;
    }

    final srcDir = '$enginePath/src';
    final srcExists = await Directory(srcDir).exists();
    final srcStatus = srcExists ? 'OK' : 'NOT FOUND';

    _logger.info('Engine path: $enginePath');
    _logger.info('Source dir:  $srcDir [$srcStatus]');

    // Detect host CPU
    final hostArch = await F.getHostCpuArch();
    _logger.info('Host CPU:    $hostArch');

    // Scan for available builds
    if (srcExists) {
      final outDir = Directory('$srcDir/out');
      if (await outDir.exists()) {
        final builds = <String>[];
        await for (final entity in outDir.list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            final sizeResult = await Process.run('du', ['-sh', entity.path]);
            final size = (sizeResult.stdout as String).split('\t').first.trim();
            builds.add('  $name${' ' * (30 - name.length).clamp(0, 30)}$size');
          }
        }

        _logger.info('');
        if (builds.isEmpty) {
          _logger.info('Available builds: (none)');
        } else {
          _logger.info('Available builds:');
          for (final build in builds) {
            _logger.info(build);
          }
        }
      } else {
        _logger.info('');
        _logger.info('Available builds: (no out/ directory)');
      }
    }

    // Check for Flutter project
    final hasPubspec = await File('pubspec.yaml').exists();
    _logger.info('');
    _logger.info(
      'Flutter project: ${hasPubspec ? 'yes (pubspec.yaml found)' : 'no'}',
    );

    return ExitCode.success.code;
  }
}
