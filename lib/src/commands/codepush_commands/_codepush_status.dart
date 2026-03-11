import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushStatusSubCommand extends Command<int> {
  CodePushStatusSubCommand(this._logger) {
    argParser.addOption(
      'app-id',
      help: 'The app ID to check status for.',
    );
  }

  final Logger _logger;

  @override
  final String name = 'status';
  @override
  final String description = 'Show releases and patches for an app.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    var appId = argResults?['app-id'] as String?;
    appId ??= await CodePushClient.getAppId();
    if (appId == null || appId.isEmpty) {
      _logger.err(
        'No app ID specified. Use --app-id or run "fcp config set codepush_app_id <id>".',
      );
      return ExitCode.usage.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = _logger.progress('Fetching status');

    try {
      final releasesResult = await client.listReleases(
        token: token,
        appId: appId,
      );

      final statusCode = releasesResult['status_code'] as int;

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 200) {
        progress.fail('Error: ${releasesResult['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      progress.complete('Status for app $appId');

      final releases = releasesResult['releases'] as List<dynamic>? ?? [];

      if (releases.isEmpty) {
        _logger.info('\n  No releases yet. Run "fcp codepush release" to create one.');
        return ExitCode.success.code;
      }

      _logger.info('');
      for (final r in releases) {
        final release = r as Map<String, dynamic>;
        _logger.info('  Release ${release['version']}');
        _logger.info('    ID:      ${release['id']}');
        _logger.info('    Created: ${release['created_at']}');

        // Fetch patches for this release.
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
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }
}
