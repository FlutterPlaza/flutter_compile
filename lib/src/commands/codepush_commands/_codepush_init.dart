import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:mason_logger/mason_logger.dart';

/// Ensures `<uses-permission android:name="android.permission.INTERNET"/>` is
/// declared in the (release) manifest. Returns the manifest unchanged if the
/// permission is already present, otherwise inserts it right after the opening
/// `<manifest ...>` tag. `flutter create` declares INTERNET only in the
/// debug/profile manifests, so a release build otherwise cannot reach the
/// update server and code push fails at runtime with a SocketException.
String ensureInternetPermission(String manifest) {
  // Ignore XML comments when checking, so a commented-out permission
  // (e.g. a scaffold's "uncomment for release" hint) still gets a real
  // declaration inserted.
  final uncommented = manifest.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  if (uncommented.contains('android.permission.INTERNET')) {
    return manifest;
  }
  final match = RegExp(r'<manifest\b[^>]*>').firstMatch(manifest);
  if (match == null) {
    return manifest;
  }
  const permission =
      '\n    <uses-permission android:name="android.permission.INTERNET"/>';
  return manifest.substring(0, match.end) +
      permission +
      manifest.substring(match.end);
}

/// Computes the manifest content `fcp codepush init` should write, or null
/// when no write is needed. This is the write decision for all three manifest
/// states, kept pure so each branch is directly testable:
///
/// - fresh scaffold (`${applicationName}` placeholder): the INTERNET
///   permission is ensured and the placeholder is pointed at `.CodePushApp`;
/// - custom Application class (no placeholder, no `CodePushApp`): only the
///   INTERNET permission is ensured — the Application class stays untouched
///   (the caller warns with wiring instructions);
/// - re-run (`CodePushApp` already wired): only a missing INTERNET
///   permission triggers a write, so repeat runs are no-ops.
String? computeManifestUpdate(String manifestContent) {
  final updated = ensureInternetPermission(manifestContent);
  if (updated.contains('android:name="\${applicationName}"')) {
    return updated.replaceFirst(
      'android:name="\${applicationName}"',
      'android:name=".CodePushApp"',
    );
  }
  return updated == manifestContent ? null : updated;
}

/// The `android:name` attribute of the `<application ...>` element, or null.
/// Scoped to the application tag so permission declarations above it can't
/// be mistaken for the Application class name.
String? findApplicationClassName(String manifestContent) {
  final applicationTag =
      RegExp(r'<application\b[^>]*>').firstMatch(manifestContent)?.group(0);
  if (applicationTag == null) return null;
  return RegExp(r'android:name="([^"]+)"').firstMatch(applicationTag)?.group(1);
}

/// The asset-copy body of the generated `CodePushApp.onCreate()`. The
/// copy must run on every launch: the asset is the source of truth and
/// changes with each app update, while a copy guarded by `exists()`
/// would stay frozen at whatever the first install shipped.
const String kCodePushAppCopyBlock = '''
        try {
            val dest = File(filesDir, "codepush.yaml")
            assets.open("codepush.yaml").use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (e: Exception) {
            android.util.Log.e("CodePushApp", "Failed to copy codepush.yaml", e)
        }''';

/// The exists-guarded copy body a pre-0.19 CLI generated.
const String _kLegacyCodePushAppCopyBlock = '''
        try {
            val dest = File(filesDir, "codepush.yaml")
            if (!dest.exists()) {
                assets.open("codepush.yaml").use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            }
        } catch (_: Exception) {}''';

/// The v1-embedding import and superclass earlier CLI versions
/// scaffolded, and the plain-`Application` pair that replaces them.
///
/// `io.flutter.app.FlutterApplication` is an EMPTY, `@Deprecated`
/// subclass of `android.app.Application`, kept only so v1-embedding
/// projects still compile; its own doc tells a project that needs to
/// extend `Application` to extend `android.app.Application` instead.
/// Extending it buys nothing, warns in a file the app author did not
/// write, and makes every scaffolded project a removal candidate's
/// hostage. `filesDir`, `assets` and the pre-`super.onCreate()` ordering
/// are all `Application` members, so the swap changes no behavior — and
/// it makes the scaffold match what the manifest's default
/// `applicationName` already resolves to.
const String _kLegacyEmbeddingImport =
    'import io.flutter.app.FlutterApplication';
const String kCodePushAppImport = 'import android.app.Application';
const String _kLegacyEmbeddingSuperclass =
    'class CodePushApp : FlutterApplication()';
const String kCodePushAppSuperclass = 'class CodePushApp : Application()';

/// The `CodePushApp.kt` source `fcp codepush init` scaffolds for
/// [packageName]. Pure so the generated shape — which the docs mirror
/// as the manual recovery path — is pinned by tests rather than by
/// reading a string literal buried in a file-writing branch.
String codePushAppKotlinSource(String packageName) => '''
package $packageName

$kCodePushAppImport
import java.io.File

$kCodePushAppSuperclass {
    override fun onCreate() {
        // Copy codepush.yaml from assets to files dir before Flutter engine init.
$kCodePushAppCopyBlock
        super.onCreate()
    }
}
''';

/// [source] with CRLF line endings collapsed to LF.
///
/// Every gate below matches text joined with `\n`, but `CodePushApp.kt`
/// is a COMMITTED source file and Git for Windows defaults to
/// `core.autocrlf=true` — so a re-run of `init` on a Windows checkout
/// reads it back as CRLF. Without normalizing, the single-line
/// embedding gates still matched while the multi-line copy gate never
/// did: the file was rewritten, the user was told "Updated", and the
/// frozen-config bug the copy migration exists to fix survived. The
/// current file fared no better — it warned "has been modified" on
/// every run, for a file nobody had touched.
String _lf(String source) => source.replaceAll('\r\n', '\n');

/// The exists-guarded copy body still needs a human: it is neither what
/// this CLI generates nor a shape the migration recognizes, so `init`
/// left it as it is.
const String kCodePushAppCopyFixWarning =
    'CodePushApp.kt keeps a copy of codepush.yaml that this CLI did not '
    'generate (the file has been modified), so it was left as it is. '
    'Make sure that copy runs on every launch — remove any exists-check '
    'around it, or the app keeps serving whatever config its first '
    'install shipped.';

/// The file still names the deprecated v1-embedding base class, in a
/// shape the migration deliberately refuses to rewrite.
const String kCodePushAppLegacyEmbeddingWarning =
    'CodePushApp.kt still references the deprecated '
    'io.flutter.app.FlutterApplication, in a shape this CLI did not '
    'generate — it was left as it is. Change it by hand to '
    '"$kCodePushAppImport" and "$kCodePushAppSuperclass".';

/// Whether [source] lacks the generated asset-copy body, so the copy
/// migration could not be applied and a human still has to fix it.
bool codePushAppNeedsCopyFix(String source) =>
    !_lf(source).contains(kCodePushAppCopyBlock);

/// Whether [source] still references the deprecated v1-embedding base
/// class. True only for a half-matching pair the rewrite leaves alone
/// (a renamed class, or the import without the superclass): leaving
/// such a file untouched is right, saying nothing about it is not.
bool codePushAppUsesLegacyEmbedding(String source) {
  final normalized = _lf(source);
  return normalized.contains(_kLegacyEmbeddingImport) ||
      normalized.contains(_kLegacyEmbeddingSuperclass);
}

/// The rewrite `init` applies to an EXISTING `CodePushApp.kt`, with one
/// note per migration applied — or null when the file needs no change.
///
/// Two independent migrations, both keyed on the EXACT text an earlier
/// CLI generated, so a file the app author has since edited is left
/// alone (the caller warns instead):
///
///  * the exists-guarded copy body → the copy-every-launch body;
///  * the deprecated v1-embedding base class → `android.app.Application`.
///
/// The embedding swap requires BOTH the import and the superclass line
/// to match: rewriting the import alone would leave a dangling
/// `FlutterApplication` reference in a file we no longer understand.
///
/// Matching is line-ending agnostic (see [_lf]); the result is handed
/// back in the endings the input carried, so a Windows checkout is not
/// silently converted to LF by an upgrade run.
({String source, List<String> notes})? upgradeCodePushAppSource(
  String existing,
) {
  final wasCrlf = existing.contains('\r\n');
  var source = _lf(existing);
  final notes = <String>[];
  if (source.contains(_kLegacyCodePushAppCopyBlock)) {
    source = source.replaceFirst(
      _kLegacyCodePushAppCopyBlock,
      kCodePushAppCopyBlock,
    );
    notes.add('Updated: CodePushApp.kt (config now refreshes on every launch)');
  }
  if (source.contains(_kLegacyEmbeddingImport) &&
      source.contains(_kLegacyEmbeddingSuperclass)) {
    source = source
        .replaceFirst(_kLegacyEmbeddingImport, kCodePushAppImport)
        .replaceFirst(_kLegacyEmbeddingSuperclass, kCodePushAppSuperclass);
    notes.add(
      'Updated: CodePushApp.kt (extends android.app.Application; the '
      'previous base class is deprecated)',
    );
  }
  if (notes.isEmpty) return null;
  return (
    source: wasCrlf ? source.replaceAll('\n', '\r\n') : source,
    notes: notes,
  );
}

/// Everything `init` should do about an EXISTING `CodePushApp.kt`.
///
/// Pure so the DISPATCH is pinned by tests, not just the rewrite. The
/// rewrite and the warnings answer independent questions, and chaining
/// them (`if (upgraded != null) … else if (needs a fix) warn`) is what
/// let an embedding-only rewrite report "Updated" while silently
/// swallowing the warning that a hand-edited copy body was still
/// freezing the app's config. Warnings are therefore computed from the
/// POST-upgrade source, whether or not anything was upgraded.
({String? source, List<String> notes, List<String> warnings, String summary})
    reconcileCodePushAppSource(String existing) {
  final upgraded = upgradeCodePushAppSource(existing);
  final effective = upgraded?.source ?? existing;
  return (
    source: upgraded?.source,
    notes: upgraded?.notes ?? const <String>[],
    warnings: <String>[
      if (codePushAppNeedsCopyFix(effective)) kCodePushAppCopyFixWarning,
      if (codePushAppUsesLegacyEmbedding(effective))
        kCodePushAppLegacyEmbeddingWarning,
    ],
    summary: upgraded != null
        ? 'Updated: CodePushApp.kt'
        : 'CodePushApp.kt: already configured',
  );
}

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
      // Via the URI rather than splitting on '/': a Windows path is
      // separated by '\', so the split returned the whole path as the
      // app name. A directory URI ends in a separator, so the trailing
      // empty segment is dropped.
      final segments = Directory.current.uri.pathSegments
          .where((segment) => segment.isNotEmpty);
      appName ??= segments.isEmpty ? 'app' : segments.last;
    }

    final platform = argResults?['platform'] as String?;
    final serverUrl = await CodePushClient.getServerUrl();

    // Generate the keypair BEFORE the app-create call so the public key
    // rides the same POST and signature verification is on from the
    // first patch. If key gen fails (openssl missing), we still create
    // the app — it'll be grandfathered and the user can run
    // `fcp codepush keys register` later.
    // Via F.homeDir() so the key path resolves on Windows too
    // (USERPROFILE rather than HOME), and so tests can redirect it.
    final home = F.homeDir();
    final keyDir = '$home/.flutter_codepush';
    final privateKeyPath = '$keyDir/codepush_private.pem';
    final publicKeyPath = '$keyDir/codepush_public.pem';
    var keysGeneratedThisRun = false;
    if (!File(privateKeyPath).existsSync()) {
      final keyProgress = _logger.progress('Generating RSA signing key pair');
      final buildService = CodePushBuildService(logger: _logger);
      // Process.runSync throws (rather than exiting nonzero) when the
      // openssl executable is missing entirely — and this block now runs
      // outside the command's main try/catch, so degrade in place.
      (String, String)? keyResult;
      try {
        keyResult = await buildService.generateSigningKey(keyDir);
      } catch (_) {
        keyResult = null;
      }
      if (keyResult != null) {
        await CodePushClient.storeSigningKey(keyResult.$1);
        keyProgress.complete('Signing keys generated');
        _logger.info('  Private key: ${keyResult.$1}');
        _logger.info('  Public key:  ${keyResult.$2}');
        keysGeneratedThisRun = true;
      } else {
        keyProgress.fail('Could not generate signing keys (openssl missing?)');
        _logger.warn(
          'Patches will not be signed. Install openssl, then run '
          '`fcp codepush keys generate` and `fcp codepush keys register`.',
        );
      }
    }
    String? publicKeyPemForCreate;
    if (File(publicKeyPath).existsSync()) {
      publicKeyPemForCreate = File(publicKeyPath).readAsStringSync().trim();
    }

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
        if (publicKeyPemForCreate != null) 'public_key': publicKeyPemForCreate,
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

      if (keysGeneratedThisRun) {
        _logger.info(
          '  Public key was registered with this app — signature '
          'verification is enabled from your first patch.',
        );
      } else if (File(privateKeyPath).existsSync()) {
        _logger.info('  Signing key: $privateKeyPath (existing)');
        if (publicKeyPemForCreate != null) {
          _logger.info(
            '  Public key was uploaded with this app, signature '
            'verification is enabled.',
          );
        }
      }

      _logger.info('  Stored in ~/.flutter_compilerc');

      // ── Native setup ──────────────────────────────────────────
      final version = _readPubspecVersion() ?? '1.0.0+1';
      _logger.info('');
      _setupAndroid(
        appId,
        version,
        storedSigningKeyPath: await CodePushClient.getStoredSigningKey(),
      );
      _setupIos(version);
      _setupPubspec();
      _logger.info('');
      _logger.success('Code push initialized! Next steps:');
      _logger.info('  1. Wrap your app with CodePushOverlay in main.dart:');
      _logger.info('');
      _logger.info(
          '     import \'package:flutterplaza_code_push/flutterplaza_code_push.dart\';');
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
        // Interpolated, not retyped: this block is what a customer
        // reads when the automated step did not finish, i.e. exactly
        // when the generated file is missing. The two must never
        // describe different base classes.
        '    b. Create CodePushApp.kt next to MainActivity.kt:\n'
        '         package <your.package>\n'
        '         $kCodePushAppImport\n'
        '         import java.io.File\n'
        '         $kCodePushAppSuperclass {\n'
        '           override fun onCreate() {\n'
        '             try {\n'
        '               val dest = File(filesDir, "codepush.yaml")\n'
        '               assets.open("codepush.yaml").use { i ->\n'
        '                 dest.outputStream().use { o -> i.copyTo(o) }\n'
        '               }\n'
        '             } catch (e: Exception) {\n'
        '               android.util.Log.e("CodePushApp", "copy failed", e)\n'
        '             }\n'
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

  void _setupAndroid(
    String appId,
    String version, {
    String? storedSigningKeyPath,
  }) {
    final androidDir = Directory('android/app/src/main');
    if (!androidDir.existsSync()) {
      _logger.detail('No android directory — skipping Android setup.');
      return;
    }

    final progress = _logger.progress('Setting up Android');

    // 1. Create codepush.yaml in assets. Include the signing public key
    // when one exists so devices verify patch signatures (parity with the
    // FLTCodePushPublicKey Info.plist entry on iOS).
    final assetsDir = Directory('${androidDir.path}/assets');
    if (!assetsDir.existsSync()) assetsDir.createSync(recursive: true);
    final configFile = File('${assetsDir.path}/codepush.yaml');
    var keyBlock =
        _publicKeyYamlBlock(storedSigningKeyPath: storedSigningKeyPath);
    if (keyBlock.isEmpty && configFile.existsSync()) {
      // No local key (CI, different machine, post-rotation) — keep a key
      // previously injected by `fcp codepush keys register` rather than
      // silently disabling signature verification on devices.
      final match =
          kPublicKeyYamlBlockPattern.firstMatch(configFile.readAsStringSync());
      if (match != null) {
        keyBlock = match.group(0)!;
        if (!keyBlock.endsWith('\n')) keyBlock = '$keyBlock\n';
        _logger.warn(
          'Preserved the existing public_key in codepush.yaml (no local '
          'signing key found). If you rotated keys, run '
          '`fcp codepush keys register` to embed the new one.',
        );
      }
    }
    configFile.writeAsStringSync(
      'enabled: true\nrelease_version: "$version"\n$keyBlock',
    );

    // 2. Find the package name and source directory
    final manifest = File('${androidDir.path}/AndroidManifest.xml');
    if (!manifest.existsSync()) {
      progress.fail('AndroidManifest.xml not found');
      return;
    }
    final manifestContent = manifest.readAsStringSync();

    // Find package name from manifest, build.gradle.kts, or build.gradle
    var packageName =
        RegExp(r'package="([^"]+)"').firstMatch(manifestContent)?.group(1);
    if (packageName == null) {
      // Try build.gradle.kts
      for (final gradleFile in [
        File('android/app/build.gradle.kts'),
        File('android/app/build.gradle'),
      ]) {
        if (gradleFile.existsSync()) {
          final gradleContent = gradleFile.readAsStringSync();
          final nsMatch =
              RegExp(r'namespace\s*[=:]\s*["\x27]([^"\x27]+)["\x27]')
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
    // Hoisted out of the branch: an upgrade run used to print both
    // "Updated: CodePushApp.kt (…)" and, in the summary below,
    // "Created: CodePushApp.kt" for the same file.
    var codePushAppSummary = 'Created: CodePushApp.kt';
    if (!codePushAppFile.existsSync()) {
      codePushAppFile.writeAsStringSync(codePushAppKotlinSource(packageName));
    } else {
      // Upgrade a CodePushApp.kt generated by an older CLI version: one
      // that skipped the copy when the file already existed, and/or one
      // built on the deprecated v1-embedding base class. What to write,
      // say and warn is decided by a pure function so the dispatch is
      // testable — see reconcileCodePushAppSource.
      final outcome = reconcileCodePushAppSource(
        codePushAppFile.readAsStringSync(),
      );
      final upgradedSource = outcome.source;
      if (upgradedSource != null) {
        codePushAppFile.writeAsStringSync(upgradedSource);
      }
      for (final note in outcome.notes) {
        _logger.info('  $note');
      }
      for (final warning in outcome.warnings) {
        _logger.warn('  $warning');
      }
      codePushAppSummary = outcome.summary;
    }

    // 4. Update AndroidManifest.xml: use CodePushApp and ensure the INTERNET
    // permission. `flutter create` only declares INTERNET in the debug/profile
    // manifests, so a --release build cannot reach the update server without
    // this — code push silently fails at runtime (SocketException).
    final updatedManifest = computeManifestUpdate(manifestContent);
    if (updatedManifest != null) {
      manifest.writeAsStringSync(updatedManifest);
    }
    if (!manifestContent.contains('android:name="\${applicationName}"') &&
        !manifestContent.contains('CodePushApp')) {
      // Custom Application class (possibly per-flavor) — the INTERNET fix
      // was written above if needed, but the Application wiring is left to
      // the user.
      final existingClass =
          findApplicationClassName(manifestContent) ?? '(unknown)';
      _logger.warn(
        'AndroidManifest.xml already has a custom Application class: '
        '$existingClass\n'
        '  Add this to its onCreate() BEFORE super.onCreate():\n'
        '    try {\n'
        '      val dest = java.io.File(filesDir, "codepush.yaml")\n'
        '      assets.open("codepush.yaml").use { i ->\n'
        '        dest.outputStream().use { o -> i.copyTo(o) }\n'
        '      }\n'
        '    } catch (e: Exception) {\n'
        '      android.util.Log.e("CodePushApp", "Failed to copy codepush.yaml", e)\n'
        '    }',
      );
    }

    progress.complete('Android configured');
    _logger.info('  Created: assets/codepush.yaml');
    _logger.info('  $codePushAppSummary');
    _logger.info(
      updatedManifest != null
          ? '  Updated: AndroidManifest.xml'
          : '  AndroidManifest.xml: already configured',
    );
  }

  /// Returns a `public_key: |` YAML block for codepush.yaml when a local
  /// signing public key exists, or an empty string otherwise. With a key
  /// in the config, devices require a valid patch signature; without one,
  /// only integrity checks run.
  String _publicKeyYamlBlock({String? storedSigningKeyPath}) {
    // Prefer the public key sitting next to the stored signing key (covers
    // `keys generate --output-dir <custom>`), then the default location.
    final candidates = <String>[
      if (storedSigningKeyPath != null && storedSigningKeyPath.isNotEmpty)
        '${File(storedSigningKeyPath).parent.path}/codepush_public.pem',
      '${F.homeDir()}/.flutter_codepush/codepush_public.pem',
    ];
    for (final candidate in candidates) {
      final publicKeyFile = File(candidate);
      if (!publicKeyFile.existsSync()) continue;
      final String pem;
      try {
        pem = publicKeyFile.readAsStringSync().trim();
      } on FileSystemException catch (e) {
        _logger.warn(
          'Could not read ${publicKeyFile.path}: $e — continuing without '
          'embedding the public key.',
        );
        continue;
      }
      if (pem.isEmpty) continue;
      final indented =
          pem.split('\n').map((line) => '  ${line.trim()}').join('\n');
      return 'public_key: |\n$indented\n';
    }
    return '';
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
      // Read the public key if it exists, for signature verification.
      var publicKeyBlock = '';
      // Via F.homeDir() so the key path resolves on Windows too
      // (USERPROFILE rather than HOME), and so tests can redirect it.
      final home = F.homeDir();
      final publicKeyFile = File('$home/.flutter_codepush/codepush_public.pem');
      if (publicKeyFile.existsSync()) {
        final pem = publicKeyFile.readAsStringSync().trim();
        publicKeyBlock = '\t<key>FLTCodePushPublicKey</key>\n'
            '\t<string>$pem</string>\n';
      }

      content = content.replaceFirst(
        '</dict>\n</plist>',
        '\t<key>FLTCodePushEnabled</key>\n'
            '\t<true/>\n'
            '\t<key>FLTCodePushReleaseVersion</key>\n'
            '\t<string>$version</string>\n'
            '$publicKeyBlock'
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
    _logger.info(
        '  Updated: Info.plist (FLTCodePushEnabled, release version, public key)');
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
