import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/tui/tui_app.dart';
import 'package:mason_logger/mason_logger.dart';

class UiCommand extends Command<int> {
  UiCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'ui';

  @override
  final String description = 'Open the terminal UI dashboard.';

  @override
  Future<int> run() async {
    if (!stdout.hasTerminal) {
      _logger.err('The ui command requires an interactive terminal.');
      return ExitCode.usage.code;
    }
    final app = TuiApp(logger: _logger);
    return app.run();
  }
}
