import 'dart:io';

import 'package:flutter_compile/src/shared/constants.dart';
import 'package:test/test.dart';

void main() {
  group('Constants paths', () {
    test('baseCliPath starts with /', () {
      expect(Constants.baseCliPath, startsWith('/'));
    });

    test('sdkVersionsPath includes baseCliPath', () {
      expect(Constants.sdkVersionsPath, contains(Constants.baseCliPath));
    });

    test('flutterCompileBin includes baseCliPath', () {
      expect(Constants.flutterCompileBin, contains(Constants.baseCliPath));
    });

    test('engineInstallPath includes baseCliPath', () {
      expect(Constants.engineInstallPath, contains(Constants.baseCliPath));
    });

    test('depotToolsInstallPath includes baseCliPath', () {
      expect(Constants.depotToolsInstallPath, contains(Constants.baseCliPath));
    });

    test('devToolsInstallPath includes baseCliPath', () {
      expect(Constants.devToolsInstallPath, contains(Constants.baseCliPath));
    });
  });

  group('Constants URLs', () {
    test('flutterGitUrl is a valid https URL', () {
      expect(Constants.flutterGitUrl, startsWith('https://'));
      expect(Constants.flutterGitUrl, endsWith('.git'));
    });

    test('depotToolsCloneUrl is a valid https URL', () {
      expect(Constants.depotToolsCloneUrl, startsWith('https://'));
      expect(Constants.depotToolsCloneUrl, endsWith('.git'));
    });

    test('engineUpstreamSSH is a valid SSH URL', () {
      expect(Constants.engineUpstreamSSH, startsWith('git@'));
    });

    test('engineUpstreamHTTPS is a valid https URL', () {
      expect(Constants.engineUpstreamHTTPS, startsWith('https://'));
    });
  });

  group('Constants platform-aware getters', () {
    test('platformFlutterCompilePATHExport contains marker comments', () {
      final export = Constants.platformFlutterCompilePATHExport;
      expect(export, contains('flutter_compile setup CLI'));
      expect(export, contains('{{path}}'));
    });

    test('platformDepotToolsPATHExport contains depot_tools marker', () {
      final export = Constants.platformDepotToolsPATHExport;
      expect(export, contains('depot_tools'));
      expect(export, contains('{{path}}'));
    });

    test('platformDevToolsPATHExport contains path placeholder', () {
      final export = Constants.platformDevToolsPATHExport;
      expect(export, contains('{{path}}'));
    });

    test('platformSdkPATHExport contains SDK manager marker', () {
      final export = Constants.platformSdkPATHExport;
      expect(export, contains('flutter_compile SDK manager'));
      expect(export, contains('{{path}}'));
      expect(export, contains('{{pub_cache_path}}'));
    });

    test('platformRestartShell contains shell placeholder', () {
      final msg = Constants.platformRestartShell;
      expect(msg, contains('{{shell}}'));
    });

    test('platform exports match OS', () {
      if (Platform.isWindows) {
        expect(
          Constants.platformFlutterCompilePATHExport,
          equals(Constants.flutterCompilePATHExportWindows),
        );
        expect(
          Constants.platformSdkPATHExport,
          equals(Constants.sdkPATHExportWindows),
        );
        expect(
          Constants.platformRestartShell,
          equals(Constants.restartShellWindows),
        );
      } else {
        expect(
          Constants.platformFlutterCompilePATHExport,
          equals(Constants.flutterCompilePATHExport),
        );
        expect(
          Constants.platformSdkPATHExport,
          equals(Constants.sdkPATHExport),
        );
        expect(
          Constants.platformRestartShell,
          equals(Constants.restartShell),
        );
      }
    });
  });

  group('Constants enums', () {
    test('RunCommandKey has expected values', () {
      expect(RunCommandKey.flutterCompile.key, equals('flutter_path'));
      expect(RunCommandKey.devTools.key, equals('devtools_path'));
      expect(RunCommandKey.engine.key, equals('engine_path'));
      expect(RunCommandKey.depotTools.key, equals('depot_tools_path'));
    });

    test('FlutterMode has normal and compiled', () {
      expect(FlutterMode.values,
          containsAll([FlutterMode.normal, FlutterMode.compiled]));
    });
  });

  group('Constants regex', () {
    test('gitHubUserNameRegex validates usernames correctly', () {
      final regex = RegExp(Constants.gitHubUserNameRegex);
      expect(regex.hasMatch('flutter'), isTrue);
      expect(regex.hasMatch('dart-lang'), isTrue);
      expect(regex.hasMatch('user123'), isTrue);
      // Too short (single char + 2 chars = 3 minimum)
      expect(regex.hasMatch('ab'), isFalse);
      // Cannot start with hyphen
      expect(regex.hasMatch('-invalid'), isFalse);
    });
  });

  group('Constants templates', () {
    test('gclientFileTemplate contains solutions', () {
      expect(Constants.gclientFileTemplate, contains('solutions'));
      expect(Constants.gclientFileTemplate, contains('{{engine_url}}'));
    });

    test('flutterVersionFile is .flutter-version', () {
      expect(Constants.flutterVersionFile, equals('.flutter-version'));
    });

    test('globalSdkVersionKey is global_sdk_version', () {
      expect(Constants.globalSdkVersionKey, equals('global_sdk_version'));
    });
  });
}
