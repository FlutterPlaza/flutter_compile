import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:flutter_compile/src/shared/gn_utils.dart';
import 'package:mason_logger/mason_logger.dart';

class EngineBuildSubCommand extends Command<int> {
  EngineBuildSubCommand(this._logger) {
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
        help: 'Build with --unoptimized (faster dev builds)',
        defaultsTo: true,
      )
      ..addFlag(
        'simulator',
        help: 'Build for iOS simulator',
        defaultsTo: false,
      )
      ..addFlag(
        'clean',
        help: 'Clean output directory before building',
        defaultsTo: false,
      )
      ..addFlag(
        'gn',
        help: 'Force re-running GN',
        defaultsTo: false,
        negatable: false,
      )
      ..addFlag(
        'no-gn',
        help: 'Skip GN step entirely',
        defaultsTo: false,
        negatable: false,
      );
  }
  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description = 'Build the Flutter engine';

  @override
  Future<int> run() async {
    final platform = argResults?['platform'] as String;
    final cpu = argResults?['cpu'] as String?;
    final mode = argResults?['mode'] as String;
    final unoptimized = argResults?['unoptimized'] as bool;
    final simulator = argResults?['simulator'] as bool;
    final clean = argResults?['clean'] as bool;
    final forceGn = argResults?['gn'] as bool;
    final skipGn = argResults?['no-gn'] as bool;

    return buildEngine(
      _logger,
      platform: platform,
      cpu: cpu,
      mode: mode,
      unoptimized: unoptimized,
      simulator: simulator,
      clean: clean,
      forceGn: forceGn,
      skipGn: skipGn,
    );
  }
}

Future<int> buildEngine(
  Logger l, {
  required String platform,
  String? cpu,
  required String mode,
  required bool unoptimized,
  required bool simulator,
  required bool clean,
  bool forceGn = false,
  bool skipGn = false,
}) async {
  if (forceGn && skipGn) {
    l.err('Error: --gn and --no-gn are mutually exclusive.');
    return ExitCode.usage.code;
  }
  l.info('Building Flutter Engine'.blue);

  // Read engine path from .flutter_compilerc
  final home = F.homeDir();
  final rcConfigFile = File('$home/.flutter_compilerc');
  final enginePath = await F.readValueForKeyFromRcConfig(
    rcConfigFile,
    RunCommandKey.engine.key,
  );

  if (enginePath == null || enginePath.isEmpty) {
    l.err(
      'Error: Engine not installed. Run `flutter_compile install engine` first.',
    );
    return ExitCode.unavailable.code;
  }

  final srcDir = '$enginePath/src';
  if (!await Directory(srcDir).exists()) {
    l.err('Error: Engine src directory not found at $srcDir.');
    l.err('Run `gclient sync` from $enginePath first.');
    return ExitCode.unavailable.code;
  }

  // Read depot_tools path and prepend to PATH so vpython3/gn/ninja are found
  final depotToolsPath = await F.readValueForKeyFromRcConfig(
    rcConfigFile,
    RunCommandKey.depotTools.key,
  );
  final buildEnv = <String, String>{};
  if (depotToolsPath != null && depotToolsPath.isNotEmpty) {
    final currentPath = Platform.environment['PATH'] ?? '';
    buildEnv['PATH'] =
        '$depotToolsPath${Platform.isWindows ? ';' : ':'}$currentPath';
  }

  // Detect host CPU
  final hostArch = await F.getHostCpuArch();
  l.info('Host CPU: $hostArch');

  // Resolve GN flags
  final gnFlags = resolveGnFlags(
    platform: platform,
    cpu: cpu,
    mode: mode,
    unoptimized: unoptimized,
    simulator: simulator,
    hostArch: hostArch,
  );

  // Resolve output directory
  final outputDir = resolveOutputDir(
    platform: platform,
    cpu: cpu,
    mode: mode,
    unoptimized: unoptimized,
    simulator: simulator,
    hostArch: hostArch,
  );

  l.info('Output directory: out/$outputDir');
  l.info('GN flags: ${gnFlags.join(' ')}');

  // Clean if requested
  if (clean) {
    final outDir = Directory('$srcDir/out/$outputDir');
    if (await outDir.exists()) {
      l.info('Cleaning $srcDir/out/$outputDir...');
      await outDir.delete(recursive: true);
    }
  }

  // Decide whether to run GN
  final buildNinjaExists =
      await File('$srcDir/out/$outputDir/build.ninja').exists();
  final runGn = shouldRunGn(
    forceGn: forceGn,
    skipGn: skipGn,
    clean: clean,
    buildNinjaExists: buildNinjaExists,
  );

  if (runGn) {
    l.info('\nRunning GN...'.yellow);
    await F.runCommand(
      './flutter/tools/gn',
      gnFlags,
      workingDirectory: srcDir,
      environment: buildEnv,
    );
    l.info('GN completed.'.green);
  } else {
    l.info(
      '\nSkipping GN (build.ninja already exists). Use --gn to force.'.cyan,
    );
  }

  // Run ninja
  l.info('\nRunning ninja build...'.yellow);
  await F.runCommand(
    'ninja',
    ['-C', 'out/$outputDir'],
    workingDirectory: srcDir,
    environment: buildEnv,
  );

  l
    ..info('\nBuild completed successfully!'.green)
    ..info('Output: $srcDir/out/$outputDir');

  return ExitCode.success.code;
}
