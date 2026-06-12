import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

class SdkListSubCommand extends Command<int> {
  SdkListSubCommand(this._logger) {
    argParser.addFlag(
      'json',
      help: 'Output as JSON.',
      negatable: false,
    );
  }

  final Logger _logger;

  @override
  final String name = 'list';
  @override
  final String description = 'List installed Flutter SDK versions.';
  @override
  final List<String> aliases = ['ls'];

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;
    return listSdks(_logger, asJson: asJson);
  }
}

Future<List<Map<String, dynamic>>> gatherSdkList() async {
  final home = F.homeDir();
  final versionsDir = Directory('$home${Constants.sdkVersionsPath}');

  if (!versionsDir.existsSync() ||
      versionsDir.listSync().whereType<Directory>().isEmpty) {
    return <Map<String, dynamic>>[];
  }

  final entries = versionsDir
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.split('/').last != Constants.defaultSdkLink)
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final globalVersion = await F.readGlobalSdkVersion();
  final projectVersion = await F.readProjectSdkVersion();

  final sdks = <Map<String, dynamic>>[];
  for (final dir in entries) {
    final name = dir.path.split('/').last;
    sdks.add({
      'version': name,
      'path': dir.path,
      'global': name == globalVersion,
      'project': name == projectVersion,
    });
  }

  final compiledFlutterDir =
      Directory('$home${Constants.flutterCompileInstallPath}');
  if (compiledFlutterDir.existsSync()) {
    sdks.add({
      'version': 'compiled',
      'path': compiledFlutterDir.path,
      'global': false,
      'project': false,
      'contributor': true,
    });
  }

  return sdks;
}

Future<int> listSdks(Logger l, {bool asJson = false}) async {
  final sdks = await gatherSdkList();

  if (sdks.isEmpty) {
    if (asJson) {
      l.info(json.encode(<Map<String, dynamic>>[]));
    } else {
      l.info('No Flutter SDKs installed.');
      l.info(
        '\nRun "flutter_compile sdk install <version>" to install one.',
      );
    }
    return ExitCode.success.code;
  }

  if (asJson) {
    l.info(json.encode(sdks));
    return ExitCode.success.code;
  }

  l.info('Installed Flutter SDKs:\n');
  for (final sdk in sdks) {
    if (sdk['contributor'] == true) continue;
    final name = sdk['version'] as String;
    final path = sdk['path'] as String;
    final markers = <String>[];
    if (sdk['global'] == true) markers.add('global');
    if (sdk['project'] == true) markers.add('project');
    final suffix = markers.isEmpty ? '' : '  (${markers.join(', ')})';
    l.info('  $name    $path$suffix');
  }

  // Show contributor environments if they exist
  final contributor = sdks.where((s) => s['contributor'] == true);
  if (contributor.isNotEmpty) {
    l.info('\nContributor environments:');
    for (final sdk in contributor) {
      l.info(
        '  ${sdk['version']}  ${sdk['path']}    (via install flutter)',
      );
    }
  }

  return ExitCode.success.code;
}
