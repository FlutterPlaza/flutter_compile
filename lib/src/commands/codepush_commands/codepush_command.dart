import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_apps.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_billing.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_init.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_register.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_login.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_logout.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_account.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_release.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_patch.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_rollback.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_seed_secrets.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_setup.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_status.dart';
import 'package:mason_logger/mason_logger.dart';

/// {@template codepush_command}
///
/// `flutter_compile codepush`
/// `flutter_compile codepush login`
/// `flutter_compile codepush logout`
/// `flutter_compile codepush account`
/// `flutter_compile codepush release`
/// `flutter_compile codepush patch`
/// `flutter_compile codepush rollback`
/// `flutter_compile codepush status`
///
/// A [Command] to manage code push — OTA updates for Flutter apps.
/// Requires a paid FlutterPlaza subscription for release/patch operations.
///
/// {@endtemplate}
class CodePushCommand extends Command<int> {
  /// {@macro codepush_command}
  CodePushCommand(this._logger) {
    addSubcommand(CodePushSetupSubCommand(_logger));
    addSubcommand(CodePushInitSubCommand(_logger));
    addSubcommand(CodePushLoginSubCommand(_logger));
    addSubcommand(CodePushRegisterSubCommand(_logger));
    addSubcommand(CodePushLogoutSubCommand(_logger));
    addSubcommand(CodePushAccountSubCommand(_logger));
    addSubcommand(CodePushReleaseSubCommand(_logger));
    addSubcommand(CodePushPatchSubCommand(_logger));
    addSubcommand(CodePushRollbackSubCommand(_logger));
    addSubcommand(CodePushStatusSubCommand(_logger));
    addSubcommand(CodePushAppsSubCommand(_logger));
    addSubcommand(CodePushBillingSubCommand(_logger));
    addSubcommand(CodePushSeedSecretsSubCommand(_logger));
  }

  @override
  final String name = 'codepush';
  @override
  final String description =
      'Code push — OTA updates for Flutter apps (paid subscription required for release/patch).';
  @override
  final List<String> aliases = ['cp'];

  final Logger _logger;

  @override
  Future<int> run() async {
    _logger.info(description);
    _logger.info('');
    _logger.info('Available subcommands:');
    _logger.info('  setup      Download code-push-enabled engine artifacts');
    _logger.info('  init       Initialize code push for this project');
    _logger.info('  login      Authenticate with the code push server');
    _logger.info('  logout     Clear stored credentials');
    _logger.info('  account    Show subscription status');
    _logger.info('  release    Upload a baseline release (paid)');
    _logger.info('  patch      Upload a patch (paid)');
    _logger.info('  rollback   Deactivate a patch');
    _logger.info('  status       Show releases and patches');
    _logger.info('  apps         List and manage your apps');
    _logger.info('  billing      View usage and billing info');
    _logger.info('  seed-secrets Push .env secrets to GCP Secret Manager');
    return ExitCode.success.code;
  }
}
