import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushStatusSubCommand extends Command<int> {
  CodePushStatusSubCommand(this._logger) {
    argParser
      ..addOption('app-id', help: 'The app ID to check status for.')
      ..addOption(
        'release-id',
        help:
            'If set, output only the patches for this release (ignored without --json).',
      )
      ..addFlag('json', help: 'Output as JSON.', negatable: false);
  }

  final Logger _logger;

  @override
  final String name = 'status';
  @override
  final String description = 'Show releases and patches for an app.';

  @override
  Future<int> run() async {
    final asJson = argResults?['json'] == true;
    final releaseId = argResults?['release-id'] as String?;

    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      if (asJson) {
        _logger.info(json.encode({'configured': false, 'logged_in': false}));
        return ExitCode.success.code;
      }
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    var appId = argResults?['app-id'] as String?;
    appId ??= await CodePushClient.getAppId();
    if (appId == null || appId.isEmpty) {
      if (asJson) {
        _logger.info(json.encode({'configured': false, 'logged_in': true}));
        return ExitCode.success.code;
      }
      _logger.err(
        'No app ID specified. Use --app-id or run "fcp config set codepush_app_id <id>".',
      );
      return ExitCode.usage.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = asJson ? null : _logger.progress('Fetching status');

    try {
      // Patches-only mode: return patches for a specific release.
      if (asJson && releaseId != null && releaseId.isNotEmpty) {
        final patchesResult = await client.listPatches(
          token: token,
          releaseId: releaseId,
        );
        final statusCode = patchesResult['status_code'] as int;
        if (statusCode != 200) {
          // --json is a structured-output contract: emit valid JSON with an
          // explicit error field and exit 0 so callers can parse it.
          _logger.info(
            json.encode({
              'release_id': releaseId,
              'patches': <Map<String, dynamic>>[],
              'error': patchesResult['error'] ?? 'Unknown',
            }),
          );
          return ExitCode.success.code;
        }
        final patches = patchesResult['patches'] as List<dynamic>? ?? [];
        _logger.info(
          json.encode({'release_id': releaseId, 'patches': patches}),
        );
        return ExitCode.success.code;
      }

      final releasesResult = await client.listReleases(
        token: token,
        appId: appId,
      );

      final statusCode = releasesResult['status_code'] as int;

      if (statusCode == 401) {
        if (asJson) {
          _logger.info(
            json.encode({
              'configured': false,
              'logged_in': false,
              'app_id': appId,
            }),
          );
          return ExitCode.success.code;
        }
        progress?.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 200) {
        if (asJson) {
          _logger.info(
            json.encode({
              'configured': true,
              'logged_in': true,
              'app_id': appId,
              'releases': <Map<String, dynamic>>[],
              'total_patches': 0,
              'error': releasesResult['error'] ?? 'Unknown',
            }),
          );
          return ExitCode.success.code;
        }
        progress?.fail('Error: ${releasesResult['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final releases = releasesResult['releases'] as List<dynamic>? ?? [];
      final appName = releasesResult['app_name'] as String?;

      if (asJson) {
        // Fetch patch counts per release and compute a total.
        var totalPatches = 0;
        final enrichedReleases = <Map<String, dynamic>>[];
        for (final r in releases) {
          final release = Map<String, dynamic>.from(r as Map);
          final rid = release['id'] as String?;
          var count = 0;
          if (rid != null) {
            try {
              final pRes = await client.listPatches(
                token: token,
                releaseId: rid,
              );
              final list = pRes['patches'] as List<dynamic>? ?? [];
              count = list.length;
            } on Exception {
              // Leave count at 0 on failure.
            }
          }
          release['patch_count'] = count;
          totalPatches += count;
          enrichedReleases.add(release);
        }
        _logger.info(
          json.encode({
            'configured': true,
            'logged_in': true,
            'app_id': appId,
            'app_name': appName,
            'releases': enrichedReleases,
            'total_patches': totalPatches,
          }),
        );
        return ExitCode.success.code;
      }

      progress?.complete('Status for app $appId');

      if (releases.isEmpty) {
        _logger.info(
          '\n  No releases yet. Run "fcp codepush release" to create one.',
        );
        return ExitCode.success.code;
      }

      _logger.info('');
      for (final r in releases) {
        final release = r as Map<String, dynamic>;
        _logger.info('  Release ${release['version']}');
        _logger.info('    ID:      ${release['id']}');
        _logger.info('    Created: ${release['created_at']}');

        final patchesResult = await client.listPatches(
          token: token,
          releaseId: release['id'] as String,
        );

        final patches = patchesResult['patches'] as List<dynamic>? ?? [];
        if (patches.isEmpty) {
          _logger.info('    Patches: none');
        } else {
          _logger.info('    Patches:');
          for (final p in patches) {
            final patch = p as Map<String, dynamic>;
            final active = patch['is_active'] == true ? 'active' : 'inactive';
            _logger.info(
              '      #${patch['number']} — $active, ${patch['rollout_percentage']}% rollout (${patch['id']})',
            );
          }
        }
        _logger.info('');
      }

      return ExitCode.success.code;
    } catch (e) {
      if (asJson) {
        _logger.info(
          json.encode({
            'configured': false,
            'logged_in': false,
            'releases': <Map<String, dynamic>>[],
            'total_patches': 0,
            'error': '$e',
          }),
        );
        return ExitCode.success.code;
      }
      progress?.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
