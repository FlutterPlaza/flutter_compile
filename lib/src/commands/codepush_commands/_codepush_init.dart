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

      // ── Native setup ──────────────────────────────────────────
      final version = _readPubspecVersion() ?? '1.0.0+1';
      _logger.info('');
      _setupAndroid(appId, version);
      _setupIos(version);
      _setupPubspec();
      _logger.info('');
      _logger.success('Code push initialized! Next steps:');
      _logger.info('  1. Wrap your app with CodePushOverlay in main.dart:');
      _logger.info('');
      _logger.info('     import \'package:flutterplaza_code_push/flutterplaza_code_push.dart\';');
      _logger.info('');
      _logger.info('     runApp(');
      _logger.info('       CodePushOverlay(');
      _logger.info('         config: CodePushConfig(');
      _logger.info("           serverUrl: '$serverUrl',");
      _logger.info("           appId: '$appId',");
      _logger.info("           releaseVersion: '$version',");
      _logger.info('         ),');
      _logger.info('         child: MyApp(),');
      _logger.info('       ),');
      _logger.info('     );');
      _logger.info('');
      _logger.info('  2. Run: fcp codepush release --build');
      _logger.info('');
      _logger.info(
        '  If any automated step failed, do it manually:\n'
        '\n'
        '  ANDROID:\n'
        '    a. Create android/app/src/main/assets/codepush.yaml:\n'
        '         enabled: true\n'
        '         release_version: "$version"\n'
        '\n'
        '    b. Create CodePushApp.kt next to MainActivity.kt:\n'
        '         package <your.package>\n'
        '         import io.flutter.app.FlutterApplication\n'
        '         import java.io.File\n'
        '         class CodePushApp : FlutterApplication() {\n'
        '           override fun onCreate() {\n'
        '             try {\n'
        '               val dest = File(filesDir, "codepush.yaml")\n'
        '               if (!dest.exists()) {\n'
        '                 assets.open("codepush.yaml").use { i ->\n'
        '                   dest.outputStream().use { o -> i.copyTo(o) }\n'
        '                 }\n'
        '               }\n'
        '             } catch (_: Exception) {}\n'
        '             super.onCreate()\n'
        '           }\n'
        '         }\n'
        '\n'
        '    c. In AndroidManifest.xml:\n'
        '       - If using default: change android:name="\${applicationName}"\n'
        '         to android:name=".CodePushApp"\n'
        '       - If using flavors or custom Application class: add the\n'
        '         codepush.yaml copy logic to your existing Application.onCreate()\n'
        '         BEFORE super.onCreate()\n'
        '\n'
        '  iOS:\n'
        '    a. In ios/Runner/Info.plist, add before </dict>:\n'
        '         <key>FLTCodePushEnabled</key>\n'
        '         <true/>\n'
        '         <key>FLTCodePushReleaseVersion</key>\n'
        '         <string>$version</string>\n'
        '\n'
        '  PUBSPEC:\n'
        '    a. Add to pubspec.yaml dependencies:\n'
        '         flutterplaza_code_push: ^0.1.0\n'
        '    b. Run: flutter pub get',
      );

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      httpClient.close();
    }
  }

  String? _readPubspecVersion() {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) return null;
    final match = RegExp(r'^version:\s*(.+)$', multiLine: true)
        .firstMatch(pubspec.readAsStringSync());
    return match?.group(1)?.trim();
  }

  // ── Android setup ─────────────────────────────────────────────

  void _setupAndroid(String appId, String version) {
    final androidDir = Directory('android/app/src/main');
    if (!androidDir.existsSync()) {
      _logger.detail('No android directory — skipping Android setup.');
      return;
    }

    final progress = _logger.progress('Setting up Android');

    // 1. Create codepush.yaml in assets
    final assetsDir = Directory('${androidDir.path}/assets');
    if (!assetsDir.existsSync()) assetsDir.createSync(recursive: true);
    final configFile = File('${assetsDir.path}/codepush.yaml');
    configFile.writeAsStringSync(
      'enabled: true\nrelease_version: "$version"\n',
    );

    // 2. Find the package name and source directory
    final manifest = File('${androidDir.path}/AndroidManifest.xml');
    if (!manifest.existsSync()) {
      progress.fail('AndroidManifest.xml not found');
      return;
    }
    final manifestContent = manifest.readAsStringSync();

    // Find package name from manifest, build.gradle.kts, or build.gradle
    var packageName = RegExp(r'package="([^"]+)"')
        .firstMatch(manifestContent)
        ?.group(1);
    if (packageName == null) {
      // Try build.gradle.kts
      for (final gradleFile in [
        File('android/app/build.gradle.kts'),
        File('android/app/build.gradle'),
      ]) {
        if (gradleFile.existsSync()) {
          final gradleContent = gradleFile.readAsStringSync();
          final nsMatch = RegExp(r'namespace\s*[=:]\s*["\x27]([^"\x27]+)["\x27]')
              .firstMatch(gradleContent);
          if (nsMatch != null) {
            packageName = nsMatch.group(1);
            break;
          }
          final appIdMatch =
              RegExp(r'applicationId\s*[=:]\s*["\x27]([^"\x27]+)["\x27]')
                  .firstMatch(gradleContent);
          if (appIdMatch != null) {
            packageName = appIdMatch.group(1);
            break;
          }
        }
      }
    }

    if (packageName == null) {
      progress.fail('Could not find package name. Check build.gradle.');
      return;
    }

    // 3. Create CodePushApp.kt
    final kotlinDir = Directory(
      '${androidDir.path}/kotlin/${packageName.replaceAll('.', '/')}',
    );
    if (!kotlinDir.existsSync()) kotlinDir.createSync(recursive: true);
    final codePushAppFile = File('${kotlinDir.path}/CodePushApp.kt');
    if (!codePushAppFile.existsSync()) {
      codePushAppFile.writeAsStringSync('''
package $packageName

import io.flutter.app.FlutterApplication
import java.io.File

class CodePushApp : FlutterApplication() {
    override fun onCreate() {
        // Copy codepush.yaml from assets to files dir before Flutter engine init.
        try {
            val dest = File(filesDir, "codepush.yaml")
            if (!dest.exists()) {
                assets.open("codepush.yaml").use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            }
        } catch (_: Exception) {}
        super.onCreate()
    }
}
''');
    }

    // 4. Update AndroidManifest.xml to use CodePushApp
    // Only replace the default ${applicationName}. If the app uses flavors
    // or a custom Application class, warn the user to integrate manually.
    if (manifestContent.contains('android:name="\${applicationName}"')) {
      manifest.writeAsStringSync(
        manifestContent.replaceFirst(
          'android:name="\${applicationName}"',
          'android:name=".CodePushApp"',
        ),
      );
    } else if (!manifestContent.contains('CodePushApp')) {
      // App has a custom Application class (possibly per-flavor).
      final existingMatch =
          RegExp(r'android:name="([^"]+)"').firstMatch(manifestContent);
      final existingClass = existingMatch?.group(1);
      _logger.warn(
        'AndroidManifest.xml already has a custom Application class: '
        '$existingClass\n'
        '  Add this to its onCreate() BEFORE super.onCreate():\n'
        '    try {\n'
        '      val dest = java.io.File(filesDir, "codepush.yaml")\n'
        '      if (!dest.exists()) {\n'
        '        assets.open("codepush.yaml").use { i ->\n'
        '          dest.outputStream().use { o -> i.copyTo(o) }\n'
        '        }\n'
        '      }\n'
        '    } catch (_: Exception) {}',
      );
    }

    progress.complete('Android configured');
    _logger.info('  Created: assets/codepush.yaml');
    _logger.info('  Created: CodePushApp.kt');
    _logger.info('  Updated: AndroidManifest.xml');
  }

  // ── iOS setup ─────────────────────────────────────────────────

  void _setupIos(String version) {
    final plistFile = File('ios/Runner/Info.plist');
    if (!plistFile.existsSync()) {
      _logger.detail('No ios/Runner/Info.plist — skipping iOS setup.');
      return;
    }

    final progress = _logger.progress('Setting up iOS');
    var content = plistFile.readAsStringSync();

    // Add FLTCodePushEnabled if not present
    if (!content.contains('FLTCodePushEnabled')) {
      content = content.replaceFirst(
        '</dict>\n</plist>',
        '\t<key>FLTCodePushEnabled</key>\n'
        '\t<true/>\n'
        '\t<key>FLTCodePushReleaseVersion</key>\n'
        '\t<string>$version</string>\n'
        '</dict>\n</plist>',
      );
      plistFile.writeAsStringSync(content);
    } else {
      // Update the version
      content = content.replaceAllMapped(
        RegExp(
          r'<key>FLTCodePushReleaseVersion</key>\s*<string>[^<]*</string>',
        ),
        (_) =>
            '<key>FLTCodePushReleaseVersion</key>\n\t<string>$version</string>',
      );
      plistFile.writeAsStringSync(content);
    }

    progress.complete('iOS configured');
    _logger.info('  Updated: Info.plist (FLTCodePushEnabled, release version)');
  }

  // ── pubspec.yaml setup ────────────────────────────────────────

  void _setupPubspec() {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync()) return;

    var content = pubspec.readAsStringSync();

    if (content.contains('flutterplaza_code_push')) {
      _logger.detail('flutterplaza_code_push already in pubspec.yaml');
      return;
    }

    final progress = _logger.progress('Adding SDK dependency');

    // Add after the flutter sdk dependency
    final flutterSdkMatch = RegExp(
      r'(  flutter:\s*\n\s+sdk: flutter\n)',
    ).firstMatch(content);

    if (flutterSdkMatch != null) {
      content = content.replaceFirst(
        flutterSdkMatch.group(0)!,
        '${flutterSdkMatch.group(0)!}'
        '  flutterplaza_code_push: ^0.1.0\n',
      );
      pubspec.writeAsStringSync(content);
      progress.complete('Added flutterplaza_code_push to pubspec.yaml');
    } else {
      progress.fail(
        'Could not auto-add dependency. '
        'Add "flutterplaza_code_push: ^0.1.0" to pubspec.yaml manually.',
      );
    }
  }
}
