import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

/// What `keys generate` says when a keypair already exists at
/// [privateKeyPath] and `--force` was not passed.
///
/// Names the consequence that actually costs something. Devices verify
/// a patch against the public key baked into the app they are RUNNING,
/// so rotating the local keypair:
///
///   * leaves already-shipped patches working — every install holds the
///     old public key, and the patches it has were signed with the
///     matching private key;
///   * stops every FUTURE patch from reaching that install base, until
///     each device takes a store release carrying the new public key.
///
/// The previous wording said the opposite ("invalidates all previously
/// signed patches"), which made rotation read as cheap: it described the
/// harmless half and omitted the fleet-wide update outage. Public so the
/// direction of the claim is pinned by a test rather than by review.
String existingSigningKeyWarning(String privateKeyPath) =>
    'A signing key already exists at $privateKeyPath. Passing --force '
    'rotates it, which stops updates for every app already installed '
    'until each one takes a store release carrying the new public key. '
    'Patches you have already shipped keep working. Rotate for a '
    'compromised key, not as routine hygiene.';

/// `fcp codepush keys`
///
/// Top-level group for RSA signing-key management. Split into two
/// sub-sub-commands to keep each one focused:
///
///   * `fcp codepush keys generate` — create a local RSA-2048 keypair
///     under `~/.flutter_codepush/`, store the private-key path in
///     `~/.flutter_compilerc`. Idempotent; refuses to overwrite an
///     existing key unless `--force` is passed.
///   * `fcp codepush keys register` — upload the **public** key to the
///     code push server for the current app, turning on mandatory
///     signature verification for every subsequent patch. Works for
///     apps created before signing was enforced (grandfathered apps).
///
/// Exists as a standalone command so users who ran `fcp codepush init`
/// on a pre-0.15.0 CLI (when init didn't generate keys) have a clear
/// recovery path without having to re-create their server-side app.
class CodePushKeysSubCommand extends Command<int> {
  CodePushKeysSubCommand(this._logger) {
    addSubcommand(_KeysGenerateCommand(_logger));
    addSubcommand(_KeysRegisterCommand(_logger));
  }

  final Logger _logger;

  @override
  final String name = 'keys';

  @override
  final String description =
      'Manage RSA signing keys for code push (generate, register).';

  @override
  Future<int> run() async {
    _logger.info(description);
    _logger.info('');
    _logger.info('Available subcommands:');
    _logger.info(
      '  generate   Generate a local RSA keypair under ~/.flutter_codepush/',
    );
    _logger.info(
      '  register   Upload the public key to the server for the current app',
    );
    _logger.info('');
    _logger.info(
      'Typical migration flow for pre-0.15.0 users:',
    );
    _logger.info('  1. fcp codepush keys generate');
    _logger.info('  2. fcp codepush keys register');
    _logger.info(
      '  3. fcp codepush patch --build   (now signed + verified server-side)',
    );
    return ExitCode.success.code;
  }
}

class _KeysGenerateCommand extends Command<int> {
  _KeysGenerateCommand(this._logger) {
    argParser
      ..addOption(
        'output-dir',
        help: 'Directory to write the keypair into.',
        defaultsTo: _defaultKeyDir(),
      )
      ..addFlag(
        'force',
        help: 'Overwrite any existing keypair at the output path.',
        negatable: false,
      );
  }

  final Logger _logger;

  @override
  final String name = 'generate';

  @override
  final String description =
      'Generate a local RSA-2048 keypair for signing patches.';

  @override
  Future<int> run() async {
    final outputDir = argResults?['output-dir'] as String? ?? _defaultKeyDir();
    final force = argResults?['force'] as bool? ?? false;

    final privateKeyPath = '$outputDir/codepush_private.pem';

    if (File(privateKeyPath).existsSync() && !force) {
      _logger.warn(existingSigningKeyWarning(privateKeyPath));
      // Still ensure the rc file points at it so subsequent `patch`
      // runs pick it up.
      await CodePushClient.storeSigningKey(privateKeyPath);
      _logger.info('  Re-stored signing key path in ~/.flutter_compilerc');
      return ExitCode.success.code;
    }

    final buildService = CodePushBuildService(logger: _logger);
    final progress = _logger.progress('Generating RSA-2048 keypair');
    final result = await buildService.generateSigningKey(outputDir);
    if (result == null) {
      progress.fail(
        'Key generation failed. Is openssl installed and on PATH?',
      );
      return ExitCode.software.code;
    }
    progress.complete('Keypair generated');

    await CodePushClient.storeSigningKey(result.$1);

    _logger
      ..info('  Private key: ${result.$1}')
      ..info('  Public key:  ${result.$2}')
      ..info('  Stored path in ~/.flutter_compilerc')
      ..info('')
      ..info('Next step: upload the public key to the server so it can')
      ..info('verify your patch signatures:')
      ..info('')
      ..info('  fcp codepush keys register');

    return ExitCode.success.code;
  }
}

class _KeysRegisterCommand extends Command<int> {
  _KeysRegisterCommand(this._logger) {
    argParser
      ..addOption(
        'app-id',
        help: 'App ID to register the public key against. Defaults to the '
            'codepush_app_id this project resolves — the project-local '
            '.flutter_compilerc when there is one, otherwise the '
            'machine-wide ~/.flutter_compilerc.',
      )
      ..addOption(
        'public-key',
        help: 'Path to the PEM-encoded public key file. Defaults to '
            '~/.flutter_codepush/codepush_public.pem, which is written '
            'by `fcp codepush keys generate`.',
      );
  }

  final Logger _logger;

  @override
  final String name = 'register';

  @override
  final String description =
      'Upload the local public key to the server, enabling mandatory '
      'patch-signature verification for this app.';

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
        'No app ID. Pass --app-id <id>, or run '
        '`fcp codepush init --app-id <id>` to record an existing app '
        '(a bare `fcp codepush init` creates a NEW app).',
      );
      return ExitCode.usage.code;
    }

    var publicKeyPath = argResults?['public-key'] as String?;
    publicKeyPath ??= '${_defaultKeyDir()}/codepush_public.pem';

    final publicKeyFile = File(publicKeyPath);
    if (!publicKeyFile.existsSync()) {
      _logger.err(
        'Public key not found at $publicKeyPath. '
        'Run `fcp codepush keys generate` first, or pass '
        '--public-key <path> to point at an existing key.',
      );
      return ExitCode.usage.code;
    }

    final publicKeyPem = publicKeyFile.readAsStringSync().trim();
    if (!publicKeyPem.startsWith('-----BEGIN PUBLIC KEY-----') ||
        !publicKeyPem.endsWith('-----END PUBLIC KEY-----')) {
      _logger.err(
        'Public key at $publicKeyPath is not PEM-encoded '
        '("-----BEGIN PUBLIC KEY----- ... -----END PUBLIC KEY-----" '
        'expected). Regenerate with `fcp codepush keys generate`.',
      );
      return ExitCode.software.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final progress = _logger.progress(
      'Registering public key with $serverUrl',
    );

    try {
      final result = await client.registerAppPublicKey(
        token: token,
        appId: appId,
        publicKeyPem: publicKeyPem,
      );
      final statusCode = result['status_code'] as int;

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }
      if (statusCode == 404) {
        progress.fail(
          'App not found on server. Check --app-id or re-run '
          '`fcp codepush init` to create the app.',
        );
        return ExitCode.software.code;
      }
      if (statusCode >= 400) {
        final err = result['error'] as String?;
        progress.fail('Server rejected registration: ${err ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      progress.complete('Public key registered');
      _logger
        ..info('  App ID:   $appId')
        ..info('  Key path: $publicKeyPath')
        ..info('')
        ..info(
          'From now on, the server will verify the RSA-SHA256 signature '
          'on every patch you upload for this app. Unsigned patches will '
          'be rejected with HTTP 403.',
        );

      _maybeAddPublicKeyToAndroidConfig(publicKeyPem);

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }

  /// Writes the public key into android/app/src/main/assets/codepush.yaml
  /// when the project has Android code push set up, replacing any previous
  /// key so rotation takes effect on devices (parity with
  /// FLTCodePushPublicKey on iOS).
  void _maybeAddPublicKeyToAndroidConfig(String publicKeyPem) {
    if (publicKeyPem.trim().isEmpty) return;
    const yamlPath = 'android/app/src/main/assets/codepush.yaml';
    try {
      final yamlFile = File(yamlPath);
      if (!yamlFile.existsSync()) return;
      var content = yamlFile.readAsStringSync();
      final indented =
          publicKeyPem.split('\n').map((line) => '  ${line.trim()}').join('\n');
      final block = 'public_key: |\n$indented\n';
      if (content.replaceAll('\r\n', '\n').contains(block)) {
        return; // already up to date (line endings normalized)
      }
      final hadKey = kPublicKeyYamlBlockPattern.hasMatch(content);
      content = content.replaceAll(kPublicKeyYamlBlockPattern, '');
      if (content.isNotEmpty && !content.endsWith('\n')) content += '\n';
      yamlFile.writeAsStringSync('$content$block');
      _logger.info(
        hadKey
            ? 'Updated the public key in $yamlPath. Devices verify against '
                'the new key from your next release build.'
            : 'Added the public key to $yamlPath. Devices will verify patch '
                'signatures from your next release build.',
      );
    } on FileSystemException catch (e) {
      _logger.warn(
        'The key was registered on the server, but updating $yamlPath '
        'failed: $e. Re-run `fcp codepush keys register` from the project '
        'root to embed it.',
      );
    }
  }
}

String _defaultKeyDir() {
  final home = Platform.environment['HOME'] ?? '/tmp';
  return '$home/.flutter_codepush';
}
