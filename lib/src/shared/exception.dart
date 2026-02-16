/// Exception thrown by utility functions in place of calling [exit()].
///
/// Carries an [exitCode] so the command runner can translate it into
/// the process exit code.
class FlutterCompileException implements Exception {
  const FlutterCompileException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() => message;
}
