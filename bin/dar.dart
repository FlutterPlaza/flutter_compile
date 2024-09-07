import 'dart:io';

Future<void> main() async {
  final result = await Process.run('/bin/zsh', ['-c', 'which flutter']);
  final currentFlutterPath = (result.stdout as String).trim();

  print('Current Flutter Path: $currentFlutterPath');

  print(result.stdout);
}
