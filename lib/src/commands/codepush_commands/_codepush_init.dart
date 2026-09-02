import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/constants.dart';
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

/// The advisory `init` prints when this machine ALREADY had a DIFFERENT
/// app id stored machine-wide, or null when there is nothing to say.
///
/// The id used to live only in `~/.flutter_compilerc`, one per machine:
/// `init` in a second app overwrote the first app's id, and every later
/// `patch`/`release`/`status` in the FIRST project then resolved the
/// second app — uploads succeeded, `status` agreed, and only the devices
/// running the first app noticed (they never saw the patch).
///
/// What changed, and what did NOT: this project is now pinned by its own
/// project-root file, so it can never be repointed by a later `init`
/// elsewhere. The machine-wide file, however, IS still repointed — every
/// `storeAppId` mirrors the new id into it so that callers which resolve
/// without a working directory (the IDE extensions, any daemon RPC not
/// passing `directory`) keep behaving exactly as they did before project
/// files existed. So the population this advisory speaks for is the one
/// the mirror deliberately leaves exposed: OTHER projects on this machine
/// that have no file of their own and were resolving [machineAppId].
///
/// Pure and public: the condition is the whole value of the advisory,
/// and it is the kind of thing that silently stops firing.
String? machineAppIdAdvisory({
  required String? machineAppId,
  required String newAppId,
  required String appIdPath,
}) {
  final previous = machineAppId?.trim() ?? '';
  final current = newAppId.trim();
  if (previous.isEmpty) return null;
  if (previous == current) return null;
  final machineRc = '${F.homeDir()}/${CodePushClient.rcFileName}';
  final pinned = appIdPath != machineRc
      ? 'This project is pinned to $current by $appIdPath, so a later '
          '"fcp codepush init" elsewhere cannot move it. '
      : '';
  return '${pinned}The machine-wide fallback in '
      '~/${CodePushClient.rcFileName} was repointed from $previous to '
      '$current. Any OTHER project on this machine without its own '
      '${CodePushClient.rcFileName} now resolves $current instead of '
      '$previous — run "fcp codepush init --app-id $previous" there to '
      'pin it (records the id; creates nothing), or pass --app-id '
      "$previous to that project's codepush commands. Do NOT run a "
      'bare "fcp codepush init" there: that creates a NEW app.';
}

/// The message `init` prints when the server has ALREADY created the
/// app but recording its id locally failed.
///
/// Pure and public for the same reason [machineAppIdAdvisory] is: this
/// is a recovery instruction handed to an operator who is one wrong
/// move — running `init` again — away from a duplicate app, and an
/// instruction that names a directory and a command writing DIFFERENT
/// files is worse than no instruction at all.
///
/// **`fcp config set` is deliberately not offered.** It writes
/// [machineRcPath], which [rcTarget] shadows ([CodePushClient.getAppId]
/// reads the project file first). In the case that actually happens —
/// a stale, read-only project `.flutter_compilerc` — it reports success
/// while every later `release`/`patch` keeps uploading to the OLD app.
/// The two instructions that always work are writing the key into
/// [rcTarget] and passing `--app-id`, so those are the two given.
///
/// [projectFileRecorded] separates the two failures
/// [CodePushClient.storeAppId] can have: it writes the project file
/// first and mirrors into the machine-wide file second, so a throw does
/// not mean nothing landed. Telling an operator their project file is
/// unwritten when it is correct sends them to fix what is not broken.
/// `init --app-id`: records an existing app id without creating
/// anything. Public for direct testing.
Future<int> runPinExistingApp({
  required String appId,
  required Logger logger,
}) async {
  final machineAppId = await CodePushClient.getMachineAppId();
  final machineRcPath = '${F.homeDir()}/${CodePushClient.rcFileName}';
  final rcTarget = CodePushClient.projectRcFile()?.path ?? machineRcPath;
  final String appIdPath;
  try {
    appIdPath = await CodePushClient.storeAppId(appId);
  } catch (e) {
    logger.err(appIdRecordFailureMessage(
      appId: appId,
      rcTarget: rcTarget,
      machineRcPath: machineRcPath,
      error: e,
      created: false,
      // Contents, not existence: the likeliest pin failure is a
      // read-only project file carrying the OLD id — existsSync would
      // claim the pin took while every upload keeps going to the old
      // app (round 4, the round-2 false-reassurance at a new site).
      projectFileRecorded: await _rcFileCarriesAppId(rcTarget, appId),
    ));
    return ExitCode.software.code;
  }
  logger.success('Pinned app $appId in $appIdPath (no app was created).');
  final advisory = machineAppIdAdvisory(
    machineAppId: machineAppId,
    newAppId: appId,
    appIdPath: appIdPath,
  );
  if (advisory != null) logger.warn(advisory);
  return ExitCode.success.code;
}

String appIdRecordFailureMessage({
  required String appId,
  required String rcTarget,
  required String machineRcPath,
  required bool projectFileRecorded,
  required Object error,
  bool created = true,
}) {
  const key = Constants.codePushAppIdKey;
  // Pin mode (`init --app-id`) is local-only and idempotent: nothing
  // was created, and re-running it after fixing the obstacle IS the
  // recovery — the post-201 warning would forbid the safe command
  // (round 4).
  final doNotReRun = created
      ? 'Do NOT re-run "fcp codepush init" — that would '
          'create a SECOND app.'
      : 'Once the obstacle is fixed, re-running '
          '"fcp codepush init --app-id $appId" is safe — it is '
          'local-only and idempotent.';
  final lede = created ? 'App $appId was created' : 'Nothing was created';

  if (projectFileRecorded) {
    return '$lede — the id WAS recorded in '
        '$rcTarget, but the machine-wide fallback in $machineRcPath '
        'could not be updated: $error\n'
        '$doNotReRun This project already resolves $appId; only tools '
        'that resolve without a project directory (the IDE extensions) '
        'keep reading the older fallback. Add "$key: $appId" to '
        '$machineRcPath to move those too.';
  }

  // Only worth saying when the two paths really are different files;
  // outside a project root `storeAppId` targets the machine-wide file
  // itself and there is nothing to shadow.
  final shadowNote = rcTarget != machineRcPath
      ? ' "fcp config set" is not a substitute — it writes '
          '$machineRcPath, which $rcTarget takes precedence over.'
      : '';

  return '$lede — the app id $appId could not be recorded in '
      '$rcTarget: $error\n'
      '$doNotReRun Record it by adding this line to $rcTarget:\n'
      '    $key: $appId\n'
      'or by passing --app-id $appId to the codepush commands.'
      '$shadowNote';
}

/// Whether the rc file at [rcPath] already carries [appId].
///
/// Never throws: this runs inside a failure path, where a second
/// exception would replace an actionable message with a stack trace.
/// Unreadable reads as "not recorded" — the conservative answer, since
/// it produces the instructions that fix an unwritten file.
Future<bool> _rcFileCarriesAppId(String rcPath, String appId) async {
  try {
    final value = await F.readValueForKeyFromRcConfig(
      File(rcPath),
      Constants.codePushAppIdKey,
    );
    return value != null && value.trim() == appId;
  } catch (_) {
    return false;
  }
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
      )
      ..addOption(
        'app-id',
        help: 'Pin this project to an EXISTING app id instead of creating '
            'a new app. Records the id locally (the project file when run '
            'inside a project); makes no server call, uploads no key, and '
            'scaffolds nothing.',
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
    final pinAppId = (argResults?['app-id'] as String?)?.trim();
    if (pinAppId != null && pinAppId.isNotEmpty) {
      // Pin-only mode: record an EXISTING app id. Local-only by
      // design — no login, no server call, no key upload, no
      // scaffold — because the population running this is a project
      // that already has a live app (a fresh clone, or a project the
      // machine-wide repoint stranded), and every server-touching
      // step of a full init is a way to damage it.
      return runPinExistingApp(appId: pinAppId, logger: _logger);
    }
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

    // Generate the keypair BEFORE the app-create call so the public key
    // rides the same POST and signature verification is on from the
    // first patch. If key gen fails (openssl missing), we still create
    // the app — it'll be grandfathered and the user can run
    // `fcp codepush keys register` later.
    final home = Platform.environment['HOME'] ?? '/tmp';
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

    // Set the moment the server answers 201. Everything after that
    // point — recording the id, scaffolding Android/iOS — can still
    // fail, and when it does the operator must NOT be told that app
    // creation failed: they would re-run `init` and create a second
    // app. See the catch at the bottom of this method.
    String? createdAppId;

    // The spinner must end exactly once, and — once the app exists —
    // never as a failure: `progress.fail` on "Creating app" is the one
    // message that sends an operator back to `init` for a second app.
    var progressResolved = false;

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
      createdAppId = appId;

      // Read the machine-wide id BEFORE storing, so the advisory below
      // compares against what this machine resolved a moment ago rather
      // than against whatever this run just wrote.
      final machineAppId = await CodePushClient.getMachineAppId();
      final machineRcPath = '${F.homeDir()}/${CodePushClient.rcFileName}';
      final rcTarget = CodePushClient.projectRcFile()?.path ?? machineRcPath;

      final String appIdPath;
      try {
        appIdPath = await CodePushClient.storeAppId(appId);
      } catch (e) {
        // The app EXISTS server-side from here on. Falling through to
        // the generic catch would fail the "Creating app" spinner, and
        // an operator who reads that re-runs `init` and gets a DUPLICATE
        // app. The only thing that went wrong is a local write, so say
        // that, and hand the id back so nothing is stranded.
        progressResolved = true;
        progress.complete('App created');
        _logger.err(
          appIdRecordFailureMessage(
            appId: appId,
            rcTarget: rcTarget,
            machineRcPath: machineRcPath,
            projectFileRecorded: await _rcFileCarriesAppId(rcTarget, appId),
            error: e,
          ),
        );
        return ExitCode.software.code;
      }

      progressResolved = true;
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

      _logger.info('  App id stored in: $appIdPath');
      // A new untracked file in the repo root needs a word about what
      // to do with it; the id is an identifier, not a credential (the
      // login token stays machine-wide), so committing it is the
      // useful default for a team.
      if (appIdPath != machineRcPath) {
        _logger.info(
          '  That file holds only this project\'s app id — no '
          'credentials — so it is safe to commit and share with your '
          'team.',
        );
        // `storeAppId` writes a SECOND file. Naming it here is the
        // difference between an operator who knows where the fallback
        // lives and one who is surprised by the advisory below.
        _logger.info(
          '  Also mirrored to: $machineRcPath (the fallback for tools '
          'that resolve without a project directory)',
        );
      }
      final staleMachineIdWarning = machineAppIdAdvisory(
        machineAppId: machineAppId,
        newAppId: appId,
        appIdPath: appIdPath,
      );
      if (staleMachineIdWarning != null) {
        _logger.warn(staleMachineIdWarning);
      }

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
        '    b. Create CodePushApp.kt next to MainActivity.kt:\n'
        '         package <your.package>\n'
        '         import io.flutter.app.FlutterApplication\n'
        '         import java.io.File\n'
        '         class CodePushApp : FlutterApplication() {\n'
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
      final appId = createdAppId;
      if (appId != null) {
        // Same rule as the storeAppId catch above: once the server has
        // the app, no failure downstream may be reported as a failure
        // to create it.
        //
        // The spinner can still be running here — `getMachineAppId()`
        // and `projectRcFile()` sit between the 201 and the
        // `progress.complete` below — and leaving it spinning is the
        // one outcome that reads as "app creation is still going".
        if (!progressResolved) {
          progressResolved = true;
          progress.complete('App created');
        }
        _logger.err(
          'App $appId was created, but "fcp codepush init" could not '
          'finish: $e\n'
          'Do NOT re-run "fcp codepush init" — that would create a '
          'SECOND app. Pass --app-id $appId to the codepush commands, '
          'and complete any native setup steps by hand.',
        );
        return ExitCode.software.code;
      }
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
    // The copy must run on every launch: the asset is the source of truth
    // and changes with each app update, while a copy guarded by exists()
    // would stay frozen at whatever the first install shipped.
    const oldCopyBlock = '''
        try {
            val dest = File(filesDir, "codepush.yaml")
            if (!dest.exists()) {
                assets.open("codepush.yaml").use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            }
        } catch (_: Exception) {}''';
    const newCopyBlock = '''
        try {
            val dest = File(filesDir, "codepush.yaml")
            assets.open("codepush.yaml").use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (e: Exception) {
            android.util.Log.e("CodePushApp", "Failed to copy codepush.yaml", e)
        }''';
    if (!codePushAppFile.existsSync()) {
      codePushAppFile.writeAsStringSync('''
package $packageName

import io.flutter.app.FlutterApplication
import java.io.File

class CodePushApp : FlutterApplication() {
    override fun onCreate() {
        // Copy codepush.yaml from assets to files dir before Flutter engine init.
$newCopyBlock
        super.onCreate()
    }
}
''');
    } else {
      // Upgrade a CodePushApp.kt generated by an older CLI version, which
      // skipped the copy when the file already existed.
      final existing = codePushAppFile.readAsStringSync();
      if (existing.contains(oldCopyBlock)) {
        codePushAppFile.writeAsStringSync(
            existing.replaceFirst(oldCopyBlock, newCopyBlock));
        _logger.info(
            '  Updated: CodePushApp.kt (config now refreshes on every launch)');
      } else if (!existing.contains(newCopyBlock)) {
        _logger.warn(
          '  CodePushApp.kt was not upgraded automatically (the file has '
          'been modified). Make sure the codepush.yaml copy in onCreate() '
          'runs on every launch — remove any exists-check around it.',
        );
      }
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
    _logger.info('  Created: CodePushApp.kt');
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
      final home = Platform.environment['HOME'] ?? '/tmp';
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
