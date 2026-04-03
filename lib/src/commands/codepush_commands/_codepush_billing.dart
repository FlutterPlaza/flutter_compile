import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushBillingSubCommand extends Command<int> {
  CodePushBillingSubCommand(this._logger) {
    addSubcommand(_BillingUsageCommand(_logger));
  }

  final Logger _logger;

  @override
  final String name = 'billing';
  @override
  final String description = 'View billing and usage information.';

  @override
  Future<int> run() async {
    _logger.info(description);
    _logger.info('');
    _logger.info('Subcommands:');
    _logger.info('  usage    Show current usage and limits');
    return ExitCode.success.code;
  }
}

class _BillingUsageCommand extends Command<int> {
  _BillingUsageCommand(this._logger);
  final Logger _logger;

  @override
  final String name = 'usage';
  @override
  final String description = 'Show current billing usage and limits.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final progress = _logger.progress('Fetching usage');

    final httpClient = HttpClient();
    try {
      final uri = Uri.parse('$serverUrl/api/v1/billing/usage');
      final request = await httpClient.getUrl(uri);
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Accept', 'application/json');

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final data = json.decode(body) as Map<String, dynamic>;

      if (response.statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (response.statusCode != 200) {
        progress.fail('Error: ${data['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      progress.complete('Usage retrieved');

      final installs =
          data['patch_installs_this_month'] ?? data['installs_this_month'] ?? 0;
      final limit = data['monthly_limit'] ?? data['install_limit'];
      final limitStr = limit == 'unlimited' ? 'Unlimited' : '${limit ?? 'N/A'}';
      final tier = data['tier'] ?? 'free';
      final overage = data['estimated_overage_cents'] ?? 0;

      _logger.info('');
      _logger.info('  Plan:       $tier');
      _logger.info('  Installs:   $installs / $limitStr');

      if (limit != null && limit != 'unlimited' && limit is int && limit > 0) {
        final pct = (installs as int) * 100 ~/ limit;
        _logger.info('  Usage:      $pct%');
      }

      if (overage > 0) {
        _logger.info('  Overage:    \$${(overage as int) / 100}');
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }
}
