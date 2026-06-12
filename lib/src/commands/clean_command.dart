import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class CleanCommand extends Command<int> {
  CleanCommand(this._logger) {
    argParser.addFlag(
      'all',
      abbr: 'a',
      help: 'Clean all builds in the engine out/ directory.',
    );
  }

  final Logger _logger;

  @override
  final String name = 'clean';

  @override
  final List<String> aliases = ['c'];

  @override
  final String description = 'Remove engine build output directories.';

  @override
  Future<int> run() async {
    final cleanAll = argResults?['all'] as bool;
    final rest = argResults?.rest ?? [];

    // Read engine path from .flutter_compilerc
    final home = F.homeDir();
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

    final outDir = Directory('$enginePath/src/out');
    if (!await outDir.exists()) {
      _logger.info('No out/ directory found at $enginePath/src/out.');
      return ExitCode.success.code;
    }

    // Collect build directories
    final builds = <Directory>[];
    await for (final entity in outDir.list()) {
      if (entity is Directory) {
        builds.add(entity);
      }
    }

    if (builds.isEmpty) {
      _logger.info('No builds found in $enginePath/src/out.');
      return ExitCode.success.code;
    }

    if (cleanAll) {
      // Delete all builds
      _logger.info('Cleaning all builds in $enginePath/src/out...');
      for (final build in builds) {
        final name = build.path.split('/').last;
        final size = await _dirSize(build.path);
        _logger.info('  $name${_pad(name)}($size)');
        await build.delete(recursive: true);
      }
      _logger.info('Deleted ${builds.length} build(s).');
    } else if (rest.isNotEmpty) {
      // Delete a specific build
      final buildName = rest.first;
      final buildDir = Directory('${outDir.path}/$buildName');
      if (!await buildDir.exists()) {
        _logger.err('Build "$buildName" not found in $enginePath/src/out.');
        return ExitCode.usage.code;
      }
      final size = await _dirSize(buildDir.path);
      await buildDir.delete(recursive: true);
      _logger.info('Deleted $buildName ($size).');
    } else {
      // List available builds
      _logger.info('Available builds:');
      for (final build in builds) {
        final name = build.path.split('/').last;
        final size = await _dirSize(build.path);
        _logger.info('  $name${_pad(name)}$size');
      }
      _logger.info('');
      _logger.info('Usage: flutter_compile clean <build_name>');
      _logger.info('       flutter_compile clean --all');
    }

    return ExitCode.success.code;
  }

  String _pad(String name) => ' ' * (30 - name.length).clamp(0, 30);

  Future<String> _dirSize(String path) async {
    if (Platform.isWindows) {
      final result = await Process.run(
        'powershell',
        [
          '-Command',
          '(Get-ChildItem -Recurse -File "$path" '
              '| Measure-Object -Property Length -Sum).Sum / 1MB '
              '| ForEach-Object { "{0:N1}M" -f \$_ }',
        ],
      );
      return (result.stdout as String).trim();
    }
    final result = await Process.run('du', ['-sh', path]);
    return (result.stdout as String).split('\t').first.trim();
  }
}
