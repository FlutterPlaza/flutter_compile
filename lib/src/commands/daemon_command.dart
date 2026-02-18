import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/daemon/daemon_peer.dart';
import 'package:mason_logger/mason_logger.dart';

class DaemonCommand extends Command<int> {
  DaemonCommand(this._logger);

  final Logger _logger;

  @override
  final String name = 'daemon';

  @override
  final String description =
      'Start a JSON-RPC 2.0 daemon for IDE communication.\n\n'
      'Communicates over stdin/stdout using line-delimited JSON.';

  @override
  Future<int> run() async {
    final peer = DaemonPeer(logger: _logger);
    await peer.start();
    return ExitCode.success.code;
  }
}
