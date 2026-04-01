import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushInitSubCommand extends Command<int> {
  CodePushInitSubCommand(this._logger) {
    argParser
      ..addOption(
        'name',
        help: 'App name (defaults to pubspec name or directory name).',
      )
      ..addOption(
        'platform',
        help: 'Target platform (android, ios).',
      );
  }

  final Logger _logger;

  @override
  final String name = 'init';
  @override
  final String description =
      'Initialize code push for this project (creates an app on the server).';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    // Determine app name.
    var appName = argResults?['name'] as String?;
    if (appName == null || appName.isEmpty) {
      final pubspec = File('pubspec.yaml');
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        final match =
            RegExp(r'^name:\s*(.+)$', multiLine: true).firstMatch(content);
        if (match != null) appName = match.group(1)?.trim();
      }
      appName ??= Directory.current.path.split('/').last;
    }

    final platform = argResults?['platform'] as String?;
    final serverUrl = await CodePushClient.getServerUrl();
    final progress = _logger.progress('Creating app "$appName"');

    final httpClient = HttpClient();
    try {
      final request =
          await httpClient.postUrl(Uri.parse('$serverUrl/api/v1/apps'));
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Content-Type', 'application/json');
      request.headers.set('Accept', 'application/json');
      request.write(json.encode({
        'name': appName,
        if (platform != null) 'platform': platform,
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final result = json.decode(body) as Map<String, dynamic>;
      final statusCode = response.statusCode;

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 201) {
        progress.fail('Error: ${result['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final app = result['app'] as Map<String, dynamic>?;
      final appId = app?['id'] as String? ?? '';

      await CodePushClient.storeAppId(appId);

      progress.complete('App created');
      _logger.info('  App ID: $appId');
      _logger.info('  Name:   $appName');

      // Generate RSA signing key pair if not already present.
      final home = Platform.environment['HOME'] ?? '/tmp';
      final keyDir = '$home/.flutter_codepush';
      final privateKeyPath = '$keyDir/codepush_private.pem';

      if (!File(privateKeyPath).existsSync()) {
        final keyProgress = _logger.progress('Generating RSA signing key pair');
        final buildService = CodePushBuildService(logger: _logger);
        final result = await buildService.generateSigningKey(keyDir);
        if (result != null) {
          await CodePushClient.storeSigningKey(result.$1);
          keyProgress.complete('Signing keys generated');
          _logger.info('  Private key: ${result.$1}');
          _logger.info('  Public key:  ${result.$2}');
        } else {
          keyProgress
              .fail('Could not generate signing keys (openssl missing?)');
          _logger.warn(
            'Patches will not be signed. Install openssl and re-run init.',
          );
        }
      } else {
        _logger.info('  Signing key: $privateKeyPath (existing)');
      }

      _logger.info('  Stored in ~/.flutter_compilerc');

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }
}
