import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/sdk_commands/_sdk_list.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

/// `flutter_compile codepush versions`
///
/// Lists all Flutter SDK versions the code push server supports. Marks
/// which are installed locally and which one is selected as the active
/// code push Flutter version (project-pinned wins over global).
class CodePushVersionsSubCommand extends Command<int> {
  CodePushVersionsSubCommand(this._logger) {
    argParser.addFlag('json', help: 'Output as JSON.', negatable: false);
  }

  final Logger _logger;

  @override
  final String name = 'versions';
  @override
  final String description =
      'List Flutter versions supported by the code push server.';

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;

    final serverUrl = await CodePushClient.getServerUrl();
    final manager = CodePushArtifactManager(
      logger: _logger,
      baseUrl: serverUrl,
    );

    final progress = asJson ? null : _logger.progress('Fetching versions');
    final manifest = await manager.fetchSupportedVersions();
    if (manifest == null) {
      progress?.fail('Failed to fetch supported versions.');
      if (asJson) {
        // --json is a structured-output contract: emit valid JSON with an
        // explicit error field and return success so callers (VS Code /
        // IntelliJ tree providers) can parse the payload and render a
        // warning row instead of treating the process as a hard failure.
        _logger.info(
          json.encode({
            'selected': null,
            'versions': <Map<String, dynamic>>[],
            'error': 'Failed to fetch version manifest from server.',
          }),
        );
        return ExitCode.success.code;
      }
      return ExitCode.software.code;
    }
    progress?.complete('Supported versions');

    // Installed SDK names (native backend + FVM cache).
    final installed = await _gatherInstalledVersionNames();

    final globalVersion = (await F.readGlobalSdkVersion())?.trim();
    final projectVersion = (await F.readProjectSdkVersion())?.trim();

    // Selected = project-pinned if it's supported, else global if supported.
    String? selected;
    if (projectVersion != null && manifest.containsKey(projectVersion)) {
      selected = projectVersion;
    } else if (globalVersion != null && manifest.containsKey(globalVersion)) {
      selected = globalVersion;
    }

    final sortedKeys = manifest.keys.toList()..sort(_compareVersions);
    final versions = <Map<String, dynamic>>[];
    for (final v in sortedKeys) {
      versions.add({
        'version': v,
        'build_revision': manifest[v],
        'installed': installed.contains(v),
        'global': v == globalVersion,
        'project_pinned': v == projectVersion,
      });
    }

    if (asJson) {
      _logger.info(json.encode({'selected': selected, 'versions': versions}));
      return ExitCode.success.code;
    }

    _logger.info('');
    _logger.info('Supported Flutter versions:');
    for (final v in versions) {
      final name = v['version'] as String;
      final markers = <String>[];
      if (name == selected) markers.add('selected');
      if (v['installed'] == true) markers.add('installed');
      if (v['global'] == true) markers.add('global');
      if (v['project_pinned'] == true) markers.add('pinned');
      final suffix = markers.isEmpty ? '' : '  (${markers.join(', ')})';
      final marker = name == selected
          ? '*'
          : (v['installed'] == true ? ' ' : '-');
      _logger.info('  $marker $name$suffix');
    }
    if (selected == null) {
      _logger.info('');
      _logger.info(
        '  No selected code push version. Install a supported version and '
        'pin it to this project or set it as global.',
      );
    }

    return ExitCode.success.code;
  }

  /// Collect installed Flutter SDK names from the native backend and,
  /// if present, FVM's cache directory.
  Future<Set<String>> _gatherInstalledVersionNames() async {
    final names = <String>{};

    // Native backend — reuses the logic from `sdk list --json`.
    try {
      final sdks = await gatherSdkList();
      for (final s in sdks) {
        final name = s['version'] as String?;
        if (name != null && name.isNotEmpty) names.add(name);
      }
    } on Exception {
      // Ignore — no native versions directory, etc.
    }

    // FVM cache — ~/fvm/versions/<name>.
    final home = F.homeDir();
    for (final rel in ['fvm/versions', '.fvm/versions']) {
      final dir = Directory('$home/$rel');
      if (dir.existsSync()) {
        for (final entry in dir.listSync().whereType<Directory>()) {
          final name = entry.path.split('/').last;
          if (name.isNotEmpty) names.add(name);
        }
      }
    }

    return names;
  }

  /// Compare two semver-ish version strings numerically where possible,
  /// falling back to lexical order for non-numeric components.
  static int _compareVersions(String a, String b) {
    final aParts = a.split('.');
    final bParts = b.split('.');
    final len = aParts.length < bParts.length ? aParts.length : bParts.length;
    for (var i = 0; i < len; i++) {
      final ai = int.tryParse(aParts[i]);
      final bi = int.tryParse(bParts[i]);
      if (ai != null && bi != null) {
        final c = ai.compareTo(bi);
        if (c != 0) return c;
      } else {
        final c = aParts[i].compareTo(bParts[i]);
        if (c != 0) return c;
      }
    }
    return aParts.length.compareTo(bParts.length);
  }
}
