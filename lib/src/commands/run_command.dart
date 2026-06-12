import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:flutter_compile/src/shared/gn_utils.dart';
import 'package:mason_logger/mason_logger.dart';

class RunCommand extends Command<int> {
  RunCommand(this._logger) {
    argParser
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Target platform',
        allowed: ['android', 'ios', 'macos', 'linux', 'web', 'host'],
        defaultsTo: 'host',
      )
      ..addOption(
        'cpu',
        abbr: 'c',
        help: 'Target CPU architecture',
        allowed: ['arm', 'arm64', 'x64'],
      )
      ..addOption(
        'mode',
        abbr: 'm',
        help: 'Build mode',
        allowed: ['debug', 'profile', 'release'],
        defaultsTo: 'debug',
      )
      ..addFlag(
        'unoptimized',
        help: 'Use unoptimized engine build',
        defaultsTo: true,
      )
      ..addFlag(
        'simulator',
        help: 'Use iOS simulator engine build',
        defaultsTo: false,
      );
  }

  final Logger _logger;

  @override
  final String name = 'run';

  @override
  final List<String> aliases = ['r'];

  @override
  final String description =
      'Run a Flutter app with a local engine build.\n\n'
      'Extra arguments after -- are forwarded to flutter run '
      '(e.g. -- -d chrome).';

  @override
  Future<int> run() async {
    final platform = argResults?['platform'] as String;
    final cpu = argResults?['cpu'] as String?;
    final mode = argResults?['mode'] as String;
    final unoptimized = argResults?['unoptimized'] as bool;
    final simulator = argResults?['simulator'] as bool;
    final extraArgs = argResults?.rest ?? [];

    // Read engine path from .flutter_compilerc
    final home = F.homeDir();
    final rcConfigFile = File('$home/.flutter_compilerc');
    final enginePath = await F.readValueForKeyFromRcConfig(
      rcConfigFile,
      RunCommandKey.engine.key,
    );

    if (enginePath == null || enginePath.isEmpty) {
      _logger.err(
        'Error: Engine not installed. '
        'Run `flutter_compile install engine` first.',
      );
      return ExitCode.unavailable.code;
    }

    final srcDir = '$enginePath/src';
    if (!await Directory(srcDir).exists()) {
      _logger.err('Error: Engine src directory not found at $srcDir.');
      return ExitCode.unavailable.code;
    }

    // Detect host CPU
    final hostArch = await F.getHostCpuArch();

    // Resolve output directory
    final outputDir = resolveOutputDir(
      platform: platform,
      cpu: cpu,
      mode: mode,
      unoptimized: unoptimized,
      simulator: simulator,
      hostArch: hostArch,
    );

    // Verify build output exists
    final buildDir = Directory('$srcDir/out/$outputDir');
    if (!await buildDir.exists()) {
      _logger.err(
        'Error: Build output not found at $srcDir/out/$outputDir.\n'
        'Run `flutter_compile build engine` first.',
      );
      return ExitCode.unavailable.code;
    }

    // Verify we're in a Flutter project
    if (!await File('pubspec.yaml').exists()) {
      _logger.err(
        'Error: No pubspec.yaml found in the current directory.\n'
        'Run this command from a Flutter project root.',
      );
      return ExitCode.usage.code;
    }

    _logger.info('Running with local engine: $outputDir');

    await F.runCommand('flutter', [
      'run',
      '--local-engine=$outputDir',
      '--local-engine-src-path=$srcDir',
      ...extraArgs,
    ]);

    return ExitCode.success.code;
  }
}
