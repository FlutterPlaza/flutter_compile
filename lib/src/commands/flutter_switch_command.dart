import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template flutter_switch_command}
///
/// `flutter_compile switch [normal|n|compiled|c]`
///
/// A [Command] to switch between normal and compiled Flutter installations.
/// - `flutter_compile switch` or `flutter_compile s`: Switch to the default other installation which is not the current.
/// - `flutter_compile switch normal` or `flutter_compile s n`: Switch to the normal Flutter installation.
/// - `flutter_compile switch compiled` or `flutter_compile s c`: Switch to the compiled Flutter installation.
///
/// {@endtemplate}
class FlutterSwitchCommand extends Command<int> {
  FlutterSwitchCommand(this._logger);
  @override
  final String name = 'switch';
  @override
  final String description =
      'Switch between normal and compiled Flutter installations';
  @override
  final List<String> aliases = ['s'];
  final Logger _logger;

  @override
  Future<int> run() async {
    final mode =
        argResults?.rest.isNotEmpty == true ? argResults?.rest[0] : null;
    if (mode == null) {
      _logger.info('Switching to other flutter installation');
      await F.switchFlutterEnvironment();
    } else if (mode == 'normal' || mode == 'n') {
      _logger.info('Switching to normal flutter installation');
      await F.switchFlutterEnvironment(mode: FlutterMode.normal);
    } else if (mode == 'compiled' || mode == 'c') {
      _logger.info('Switching to compiled flutter installation');
      await F.switchFlutterEnvironment(mode: FlutterMode.compiled);
    } else {
      _logger.err('Invalid mode: $mode');
      return ExitCode.usage.code;
    }
    return ExitCode.success.code;
  }
}
