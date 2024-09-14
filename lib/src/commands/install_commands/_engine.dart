import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/extension.dart';
import 'package:mason_logger/mason_logger.dart';

class EngineSubCommand extends Command<int> {
  EngineSubCommand(this._logger) {
    argParser.addOption(
      'platform',
      abbr: 'p',
      help: 'Specify the platform to install (ios, android, tv)',
    );
  }
  final Logger _logger;

  @override
  final String name = 'engine';
  @override
  final String description =
      'Set up the Flutter engine development environment';

  @override
  Future<int> run() async {
    final platform = argResults?['platform'] as String;
    if (platform == '' || !['ios', 'android', 'tv'].contains(platform)) {
      printUsage();
      return ExitCode.usage.code;
    }
    await setupEngineEnvironment(_logger, platform);
    return ExitCode.success.code;
  }

  void printUsage() {}
}

Future<void> setupEngineEnvironment(Logger l, String platform) async {
  l.info('Flutter Engine Development Environment Setup for $platform'.blue);
  // Add the logic to set up the Flutter engine environment for the specified platform here
}
