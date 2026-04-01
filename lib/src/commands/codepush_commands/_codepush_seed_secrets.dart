import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushSeedSecretsSubCommand extends Command<int> {
  CodePushSeedSecretsSubCommand(this._logger) {
    argParser
      ..addOption(
        'env-file',
        help: 'Path to the .env file with secret values.',
        defaultsTo: '.env',
      )
      ..addOption(
        'project',
        help: 'GCP project ID.',
      )
      ..addFlag(
        'dry-run',
        help: 'Print what would be seeded without writing to Secret Manager.',
        defaultsTo: false,
      );
  }

  final Logger _logger;

  @override
  final String name = 'seed-secrets';
  @override
  final String description =
      'Push secrets from a .env file into GCP Secret Manager for server deployment.';

  static const _secretKeys = [
    'JWT_SECRET',
    'STRIPE_SECRET_KEY',
    'STRIPE_WEBHOOK_SECRET',
    'BREVO_API_KEY',
  ];

  String _secretName(String envKey) {
    return 'codepush-${envKey.toLowerCase().replaceAll('_', '-')}';
  }

  Map<String, String> _parseEnvFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return {};

    final entries = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final eq = trimmed.indexOf('=');
      if (eq < 1) continue;
      entries[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
    }
    return entries;
  }

  Future<bool> _gcloudAvailable() async {
    try {
      final result = await Process.run('gcloud', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _secretExists(String name) async {
    final result = await Process.run(
      'gcloud',
      ['secrets', 'describe', name, '--quiet'],
      runInShell: true,
    );
    return result.exitCode == 0;
  }

  Future<bool> _createSecret(String name) async {
    final result = await Process.run(
      'gcloud',
      [
        'secrets',
        'create',
        name,
        '--replication-policy=automatic',
        '--quiet',
      ],
      runInShell: true,
    );
    return result.exitCode == 0;
  }

  Future<bool> _addSecretVersion(String name, String value) async {
    final proc = await Process.start(
      'gcloud',
      ['secrets', 'versions', 'add', name, '--data-file=-', '--quiet'],
    );
    proc.stdin.write(value);
    await proc.stdin.close();
    final exitCode = await proc.exitCode;
    return exitCode == 0;
  }

  @override
  Future<int> run() async {
    final envPath = argResults?['env-file'] as String? ?? '.env';
    final dryRun = argResults?['dry-run'] as bool? ?? false;
    final projectId = argResults?['project'] as String?;

    // Check gcloud.
    if (!await _gcloudAvailable()) {
      _logger.err('gcloud CLI not found. Install it from '
          'https://cloud.google.com/sdk/docs/install');
      return ExitCode.software.code;
    }

    // Set project if provided.
    if (projectId != null) {
      final progress = _logger.progress('Setting GCP project to $projectId');
      final result = await Process.run(
        'gcloud',
        ['config', 'set', 'project', projectId, '--quiet'],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        progress.fail('Failed to set project: ${result.stderr}');
        return ExitCode.software.code;
      }
      progress.complete('Project set to $projectId');
    }

    // Enable Secret Manager API.
    if (!dryRun) {
      final progress = _logger.progress('Enabling Secret Manager API');
      await Process.run(
        'gcloud',
        ['services', 'enable', 'secretmanager.googleapis.com', '--quiet'],
        runInShell: true,
      );
      progress.complete('Secret Manager API enabled');
    }

    // Parse .env file.
    final envFile = File(envPath);
    if (!envFile.existsSync()) {
      _logger.err('File not found: $envPath');
      _logger.info('Create a .env file or specify a path with --env-file.');
      return ExitCode.usage.code;
    }

    final env = _parseEnvFile(envPath);
    _logger.info('');
    _logger.info('Secrets to seed from $envPath:');
    _logger.info('');

    var seeded = 0;
    var skipped = 0;

    for (final key in _secretKeys) {
      final value = env[key];
      final name = _secretName(key);

      if (value == null || value.isEmpty) {
        _logger.warn('  $key — not found in $envPath, skipping');
        skipped++;
        continue;
      }

      final masked =
          '${value.substring(0, (value.length > 8 ? 8 : value.length))}...';

      if (dryRun) {
        _logger.info('  [dry-run] $key → $name ($masked)');
        seeded++;
        continue;
      }

      final progress = _logger.progress('  $key → $name');

      // Create secret if it doesn't exist.
      if (!await _secretExists(name)) {
        if (!await _createSecret(name)) {
          progress.fail('Failed to create secret: $name');
          continue;
        }
      }

      // Add new version.
      if (await _addSecretVersion(name, value)) {
        progress.complete('$key → $name ($masked)');
        seeded++;
      } else {
        progress.fail('Failed to seed: $name');
      }
    }

    _logger.info('');
    if (dryRun) {
      _logger.info('Dry run complete. $seeded secret(s) would be seeded.');
    } else {
      _logger.success('$seeded secret(s) seeded, $skipped skipped.');
      _logger.info('');
      _logger.info('Your deploy.sh will now use --set-secrets to inject these');
      _logger
          .info('at runtime. The .env file is no longer needed for deploys.');
      _logger.warn(
        'Rotate the values in your local .env — they should not match production.',
      );
    }

    return ExitCode.success.code;
  }
}
