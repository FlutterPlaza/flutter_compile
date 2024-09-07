import 'dart:io';

void main() async {
  await Process.run('dart', ['pub', 'global', 'activate', 'flutter_compile']);
  var result = await Process.run('flutter_compile', ['--help']);
  print(result.stdout);

  await Future.wait([
    stdout.close(),
    stderr.close(),
  ]);
  exit(0);
}
