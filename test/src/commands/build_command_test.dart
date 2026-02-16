import 'package:flutter_compile/src/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

import '../../helpers/test_helpers.dart';

void main() {
  group('build', () {
    late FlutterCompileCommandRunner commandRunner;

    setUp(() {
      final fixture = createTestCommandRunner();
      commandRunner = fixture.commandRunner;
    });

    test('shows usage when no subcommand given', () async {
      final result = await commandRunner.run(['build']);
      expect(result, equals(ExitCode.usage.code));
    });
  });
}
