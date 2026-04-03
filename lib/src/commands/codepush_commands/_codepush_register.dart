import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/constants.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushRegisterSubCommand extends Command<int> {
  CodePushRegisterSubCommand(this._logger) {
    argParser
      ..addOption(
        'email',
        help: 'Email address for your account.',
      )
      ..addOption(
        'name',
        help: 'Your name (optional).',
      )
      ..addOption(
        'server',
        help: 'Code push server URL.',
        defaultsTo: Constants.codePushDefaultServer,
      );
  }

  final Logger _logger;

  @override
  final String name = 'register';
  @override
  final String description = 'Create a new Code Push account.';

  @override
  Future<int> run() async {
    final serverUrl =
        argResults?['server'] as String? ?? Constants.codePushDefaultServer;

    var email = argResults?['email'] as String?;
    if (email == null || email.isEmpty) {
      email = _logger.prompt('Enter your email:');
    }
    if (email.isEmpty) {
      _logger.err('Email is required.');
      return ExitCode.usage.code;
    }

    final name = argResults?['name'] as String?;

    final progress = _logger.progress('Creating account');
    final httpClient = HttpClient();

    try {
      final uri = Uri.parse('$serverUrl/api/v1/auth/register');
      final request = await httpClient.postUrl(uri);
      request.headers.set('Content-Type', 'application/json');
      request.write(json.encode({
        'email': email,
        if (name != null) 'name': name,
      }));

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;

      if (response.statusCode == 409) {
        progress.fail('An account already exists for $email.');
        _logger.info('Run "fcp codepush login" to sign in.');
        return ExitCode.software.code;
      }

      if (response.statusCode != 201) {
        progress.fail('Error: ${data['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final apiKey = data['api_key'] as String?;
      progress.complete('Account created');

      _logger.info('  Email: $email');
      if (apiKey != null) {
        _logger.info('  API Key: $apiKey');
        _logger.warn(
          '  Save this key — it will not be shown again.',
        );
      }

      _logger.info('');
      _logger.info(
        'Now run "fcp codepush login" to authenticate.',
      );

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }
}
