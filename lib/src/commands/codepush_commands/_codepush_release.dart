import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/shared/android_baseline_yaml.dart';
import 'package:flutter_compile/src/shared/codepush_archive_service.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/ios_baseline_plist.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';

class CodePushReleaseSubCommand extends Command<int> {
  CodePushReleaseSubCommand(this._logger) {
    argParser
      ..addOption('app-id', help: 'The app ID to create a release for.')
      ..addOption(
        'version',
        abbr: 'v',
        help: 'The version string for this release (e.g., 1.0.0+1).',
      )
      ..addOption('snapshot', help: 'Path to a pre-built release artifact.')
      ..addOption(
        'platform',
        abbr: 'p',
        help: 'Target platform (apk, appbundle, ios, linux, macos, windows).',
      )
      ..addFlag(
        'build',
        help: 'Build the app in release mode before uploading.',
        defaultsTo: false,
      )
      ..addMultiOption(
        'dart-define',
        help: 'Additional --dart-define values to forward to flutter build '
            'when --build is used. Repeat for multiple values.',
      )
      ..addOption(
        'flutter-version',
        help: 'Flutter SDK version this release was built with (e.g., 3.41.2). '
            'Auto-detected from "flutter --version" if not specified. '
            'Required for server-side patch compilation.',
      )
      ..addOption(
        'baseline-id',
        help: 'The FCPBaselineId embedded in the app being released. Needed '
            'when releasing a pre-built iOS app without --build: devices '
            'match releases by this id, so a release without one is never '
            'offered an update. With --build the id is generated and '
            'stamped automatically.',
      )
      ..addFlag(
        'allow-missing-baseline',
        help: 'Create an iOS release without a baseline identity. Devices '
            'running modern SDKs will never match it — special cases only.',
        negatable: false,
      );
  }

  final Logger _logger;

  @override
  final String name = 'release';
  @override
  final String description = 'Upload a baseline release.';

  @override
  Future<int> run() async {
    final token = await CodePushClient.getStoredToken();
    if (token == null || token.isEmpty) {
      _logger.err('Not logged in. Run "fcp codepush login" first.');
      return ExitCode.software.code;
    }

    // Resolve app ID.
    var appId = argResults?['app-id'] as String?;
    appId ??= await CodePushClient.getAppId();
    if (appId == null || appId.isEmpty) {
      _logger.err(
        'No app ID specified. Use --app-id or run "fcp config set codepush_app_id <id>".',
      );
      return ExitCode.usage.code;
    }

    // Resolve version.
    var version = argResults?['version'] as String?;
    if (version == null || version.isEmpty) {
      // Try to read from pubspec.yaml in current directory.
      final pubspec = File('pubspec.yaml');
      if (pubspec.existsSync()) {
        final content = pubspec.readAsStringSync();
        final match = RegExp(
          r'^version:\s*(.+)$',
          multiLine: true,
        ).firstMatch(content);
        if (match != null) {
          version = match.group(1)?.trim();
        }
      }
      if (version == null || version.isEmpty) {
        _logger.err(
          'No version specified. Use --version or add one to pubspec.yaml.',
        );
        return ExitCode.usage.code;
      }
      _logger.detail('Using version from pubspec.yaml: $version');
    }

    // If --build is set, build the app first.
    final shouldBuild = argResults?['build'] as bool? ?? false;
    final buildService = CodePushBuildService(logger: _logger);
    String? baselineId;
    String? originalIosInfoPlist;
    String? originalAndroidYaml;
    String? builtPlatform;

    if (shouldBuild) {
      var platform = argResults?['platform'] as String?;
      platform ??= buildService.detectPlatform();
      if (platform == null) {
        _logger.err(
          'Cannot detect platform. Use --platform to specify (apk, appbundle, ios, linux, macos, windows).',
        );
        return ExitCode.usage.code;
      }
      builtPlatform = platform;

      final artifactManager = CodePushArtifactManager(logger: _logger);

      final flutterVersion = await buildService.resolveFlutterVersion(
        explicit: argResults?['flutter-version'] as String?,
        buildPlatform: platform,
        artifactManager: artifactManager,
      );
      if (flutterVersion == null) {
        _logger.err(
          'Could not resolve Flutter SDK version. Pass --flutter-version '
          '<version>, ensure "flutter --version" works in this shell, or '
          'run "fcp codepush setup" to store a default engine version.',
        );
        return ExitCode.usage.code;
      }
      _logger.detail('Using Flutter version: $flutterVersion');

      final dartDefines =
          (argResults?['dart-define'] as List<String>? ?? const <String>[])
              .where((value) => value.isNotEmpty)
              .toList();
      final extraBuildArgs = [
        for (final value in dartDefines) '--dart-define=$value',
      ];

      try {
        final prepProgress = _logger.progress('Preparing code push build');
        final prepared = await buildService.prepareCodePushBuild(
          buildPlatform: platform,
          flutterVersion: flutterVersion,
          artifactManager: artifactManager,
        );
        if (prepared) {
          prepProgress.complete('Ready');
        } else {
          prepProgress.fail(
            'Code push build preparation failed. '
            'Run "fcp codepush setup" first.',
          );
          return ExitCode.software.code;
        }

        // Generate a UUID and write it into ios/Runner/Info.plist as
        // FCPBaselineId BEFORE `flutter build`, so it's bundled into the
        // .app. Restore the plist afterwards so `release --build` does
        // not leave the app repo dirty.
        if (platform == 'ios') {
          final generatedBaselineId = generateBaselineId();
          originalIosInfoPlist = writeBaselineIdToIosInfoPlist(
            generatedBaselineId,
          );
          if (originalIosInfoPlist == null) {
            _logger.warn(
              'Warning: ios/Runner/Info.plist not found. '
              'This build will not embed a baseline identity.',
            );
          } else {
            baselineId = generatedBaselineId;
            _logger.detail('Wrote FCPBaselineId=$baselineId to Info.plist');
          }
        }

        // Stamp the release version into the Android code push config
        // asset BEFORE `flutter build`, so the shipped APK carries the
        // version it is released as. Restored afterwards so the app repo
        // stays clean (same pattern as the iOS Info.plist stamp above).
        if ((platform == 'apk' || platform == 'appbundle') &&
            version.isNotEmpty) {
          originalAndroidYaml = writeReleaseVersionToAndroidYaml(version);
          if (originalAndroidYaml == null) {
            _logger.warn(
              'Warning: $kDefaultAndroidCodePushYamlPath not found. '
              'This build will not embed a release version. '
              'Run "fcp codepush init" to set up Android.',
            );
          } else {
            _logger.detail(
              'Stamped release_version=$version into codepush.yaml',
            );
          }
        }

        var releaseBuildArgs = extraBuildArgs;
        if (platform == 'ios') {
          releaseBuildArgs =
              CodePushBuildService.withIosReleaseGenSnapshotOptions(
            extraBuildArgs,
          );
          final freezeArgs = await _prepareIosInterfaceFreeze(buildService);
          if (freezeArgs == null) return ExitCode.software.code;
          releaseBuildArgs = freezeArgs(releaseBuildArgs);
        }

        final buildProgress = _logger.progress('Building release ($platform)');
        final buildOk = await buildService.buildRelease(
          platform: platform,
          extraArgs: releaseBuildArgs,
          artifactManager: artifactManager,
          flutterVersion: flutterVersion,
        );
        if (!buildOk) {
          buildProgress.fail('Build failed');
          return ExitCode.software.code;
        }
        buildProgress.complete('Build succeeded');

        final finalizeProgress = _logger.progress('Finalizing build');
        final finalized = await buildService.finalizeBuild(
          buildPlatform: platform,
          flutterVersion: flutterVersion,
          artifactManager: artifactManager,
        );
        if (finalized.success) {
          finalizeProgress.complete('Build finalized');
        } else {
          finalizeProgress.fail(finalized.message ?? 'Finalization failed');
          final diagnostics = finalized.formatDiagnostics();
          if (diagnostics.isNotEmpty) {
            _logger.err(diagnostics);
          }
          return ExitCode.software.code;
        }
      } finally {
        if (originalIosInfoPlist != null) {
          restoreIosInfoPlist(originalIosInfoPlist);
          _logger.detail('Restored ios/Runner/Info.plist');
        }
        if (originalAndroidYaml != null) {
          try {
            restoreAndroidYaml(originalAndroidYaml);
            _logger.detail('Restored android assets/codepush.yaml');
          } on FileSystemException catch (e) {
            // Don't mask an in-flight build error with a restore failure;
            // tell the user the repo is dirty and how to fix it.
            _logger.err(
              'Failed to restore $kDefaultAndroidCodePushYamlPath after the '
              'build: $e\nThe file still contains the stamped release '
              'version — restore it manually (e.g. git checkout -- '
              '$kDefaultAndroidCodePushYamlPath).',
            );
          }
        }
      }
    }

    // Resolve the platform once — the baseline-identity check and the
    // snapshot auto-detection both need it, and an explicit --snapshot
    // must not skip the identity check. Same precedence as the build
    // branch: explicit flag, then the platform that was just built,
    // then project detection.
    //
    // Detection alone cannot be trusted for a dual-platform project:
    // android/ is probed before ios/, so `flutter build ios` followed
    // by a flagless release would route into the Android branch — and
    // could upload a stale Android library as this version's baseline.
    // Creating a server record deserves an explicit choice.
    final explicitPlatform = argResults?['platform'] as String?;
    if (CodePushBuildService.releaseNeedsExplicitPlatform(
      explicitPlatform: explicitPlatform,
      builtPlatform: builtPlatform,
      hasAndroidDir: Directory('android').existsSync(),
      hasIosDir: Directory('ios').existsSync(),
    )) {
      _logger.err(
        'This project has both android/ and ios/ — pass --platform so '
        'the release matches the app you actually built (or use '
        '--build, which records the platform it builds).',
      );
      return ExitCode.usage.code;
    }
    final resolvedPlatform = explicitPlatform ??
        builtPlatform ??
        buildService.detectPlatform() ??
        'apk';

    // Resolve snapshot path.
    var snapshotPath = argResults?['snapshot'] as String?;
    if (snapshotPath == null || snapshotPath.isEmpty) {
      // On Android the uploaded baseline MUST be the stripped libapp.so
      // that ships inside the APK/AAB: the server hashes these bytes and
      // devices compare against a hash of the packaged file they run.
      // The pre-strip app.so that findSnapshotPath prefers hashes
      // differently, which would make every device's check miss — so a
      // missing packaged library is an error here, never a silent
      // fallback to a copy whose identity no device can match.
      if (const {'apk', 'appbundle', 'android'}.contains(resolvedPlatform)) {
        snapshotPath = buildService.findAndroidBaselineLibPath();
        if (snapshotPath == null) {
          _logger.err(
            'No packaged Android library found to upload for a supported '
            'ABI (arm64-v8a, armeabi-v7a). Run a release build first '
            '(flutter build apk / appbundle) — an emulator-only (x86) '
            'build does not produce one — or pass --snapshot with the '
            'exact library file your app ships.',
          );
          return ExitCode.usage.code;
        }
      }
      // On iOS the uploaded baseline MUST be the built App.framework/App
      // binary: it is what devices hash for the baseline check, and it
      // is a few MB. The kernel findSnapshotPath falls back to is tens
      // of MB on real apps — over the upload size cap (HTTP 413) — and
      // its hash matches nothing any device computes. A missing built
      // app is an error here, never a silent kernel upload.
      if (resolvedPlatform == 'ios') {
        snapshotPath = buildService.findIosBaselineAppBinaryPath();
        if (snapshotPath == null) {
          _logger.err(
            'No built iOS app binary found to upload. Run a release build '
            'first ("fcp codepush release --build", "flutter build ios '
            '--release", or "flutter build ipa") — a simulator-only build '
            '(build/ios/iphonesimulator) does not produce one — or pass '
            '--snapshot with the exact App.framework/App binary your app '
            'ships.',
          );
          return ExitCode.usage.code;
        }
      }
      snapshotPath ??= buildService.findSnapshotPath(resolvedPlatform);
      if (snapshotPath == null) {
        _logger.err(
          'No snapshot found. Build your app in release mode first, or use --snapshot.',
        );
        return ExitCode.usage.code;
      }
      _logger.detail('Using snapshot: $snapshotPath');
    }

    final snapshotFile = File(snapshotPath);
    if (!snapshotFile.existsSync()) {
      _logger.err('Snapshot file not found: $snapshotPath');
      return ExitCode.software.code;
    }

    // Resolve the baseline identity for iOS releases that did not just
    // stamp one (--no-build re-runs, or a build whose plist was absent).
    // A UUID-less iOS release is a landmine: devices match releases by
    // FCPBaselineId, so every update check would return nothing —
    // forever, with no error anywhere.
    //
    // Resolved AFTER the snapshot so the identity is read from the SAME
    // app bundle the uploaded bytes come from — never from a different
    // (staler or newer) build whose id would not match the binary. A
    // --snapshot pointing outside an app bundle provides no identity
    // and must use --baseline-id.
    if (resolvedPlatform == 'ios') {
      final appDirForIdentity = builtIosAppDirFromBinaryPath(snapshotPath);
      baselineId = resolveIosBaselineId(
        stampedByBuild: baselineId,
        explicitFlag: argResults?['baseline-id'] as String?,
        fromBuiltApp: appDirForIdentity != null
            ? readBaselineIdFromBuiltAppPlist(appPath: appDirForIdentity)
            : null,
      );
      if (baselineId != null) {
        _logger.detail('Using baseline id: $baselineId');
      } else if (!(argResults?['allow-missing-baseline'] as bool? ?? false)) {
        if (shouldBuild) {
          // The build ran but could not stamp: the source plist was
          // missing (warned above). Telling the user to "re-run with
          // --build" would send them in a circle.
          _logger.err(
            'The build could not stamp a baseline identity because '
            'ios/Runner/Info.plist is missing. Restore the plist '
            '("flutter create ." regenerates it) and re-run, or pass '
            '--baseline-id <uuid>.',
          );
        } else {
          _logger.err(
            'This iOS release has no baseline identity. Devices match '
            'releases by the FCPBaselineId stamped at build time; a '
            'release without one is never offered an update. Re-run with '
            '--build, pass --baseline-id <uuid> (the id embedded in the '
            'app you are releasing), or pass --allow-missing-baseline if '
            'you really want a release no modern device will match.',
          );
        }
        return ExitCode.usage.code;
      }
    }

    final snapshotData = snapshotFile.readAsBytesSync();
    _logger.detail('Snapshot size: ${snapshotData.length} bytes');

    // Resolve Flutter version for server-side compilation.
    var flutterVersion = argResults?['flutter-version'] as String?;
    if (flutterVersion == null || flutterVersion.isEmpty) {
      final flutter = buildService.findFlutterBin();
      if (flutter != null) {
        // Try --machine output first (structured JSON).
        final vResult = Process.runSync(flutter, ['--version', '--machine']);
        if (vResult.exitCode == 0) {
          try {
            final vJson = (vResult.stdout as String).trim();
            final match = RegExp(
              r'"frameworkVersion"\s*:\s*"([^"]+)"',
            ).firstMatch(vJson);
            flutterVersion = match?.group(1);
          } catch (_) {}
        }
        // Fallback: parse plain `flutter --version` output.
        if (flutterVersion == null || flutterVersion.isEmpty) {
          final plainResult = Process.runSync(flutter, ['--version']);
          if (plainResult.exitCode == 0) {
            final match = RegExp(
              r'Flutter (\d+\.\d+\.\d+)',
            ).firstMatch(plainResult.stdout as String);
            flutterVersion = match?.group(1);
          }
        }
      }
      if (flutterVersion != null) {
        _logger.detail('Detected Flutter version: $flutterVersion');
      } else {
        _logger.warn(
          'Warning: Could not detect Flutter version. Server-side compilation '
          'will not be available for this release.',
        );
      }
    }

    final serverUrl = await CodePushClient.getServerUrl();
    final client = CodePushClient(serverUrl: serverUrl);
    final versionSuffix =
        flutterVersion != null ? ' (Flutter $flutterVersion)' : '';
    final progress = _logger.progress(
      'Creating release v$version for $appId$versionSuffix',
    );

    try {
      final result = await client.createRelease(
        token: token,
        appId: appId,
        version: version,
        snapshotData: snapshotData,
        flutterVersion: flutterVersion,
        baselineId: baselineId,
      );

      final statusCode = result['status_code'] as int;

      if (statusCode == 403) {
        final serverError = result['error'] as String?;
        final upgradeUrl =
            result['upgrade_url'] as String? ?? 'flutterplaza.com/pricing';
        progress.fail(
          serverError != null
              ? '$serverError See $upgradeUrl'
              : 'Upload denied by server. See $upgradeUrl',
        );
        return ExitCode.software.code;
      }

      if (statusCode == 401) {
        progress.fail('Session expired. Run "fcp codepush login" again.');
        return ExitCode.software.code;
      }

      if (statusCode != 201) {
        progress.fail('Error: ${result['error'] ?? 'Unknown'}');
        return ExitCode.software.code;
      }

      final release = result['release'] as Map<String, dynamic>?;
      progress.complete('Release $version uploaded');

      if (release != null) {
        _logger.info('  Release ID:      ${release['id']}');
        _logger.info('  Version:         ${release['version']}');
        _logger.info('  Hash:            ${release['snapshot_hash']}');
        if (release['baseline_id'] != null) {
          _logger.info('  Baseline ID:     ${release['baseline_id']}');
        }
        if (release['flutter_version'] != null) {
          _logger.info('  Flutter version: ${release['flutter_version']}');
        }
      }

      // Save the iOS baseline app for later device install.
      if (builtPlatform == 'ios' && baselineId != null) {
        _saveIosBaselineApp(baselineId: baselineId);

        // Archive the saved baseline app + dSYM into a per-release
        // directory so a future device replay can reinstall the exact
        // bundle that produced this release. Best-effort; never fails
        // a successful release.
        final releaseId = release?['id'] as String?;
        if (releaseId != null) {
          CodePushArchiveService(logger: _logger).archiveIosRelease(
            releaseId: releaseId,
            baselineId: baselineId,
            fcpVersion: packageVersion,
          );
        }
      }

      return ExitCode.success.code;
    } catch (e) {
      progress.fail('Failed: $e');
      return ExitCode.software.code;
    } finally {
      client.close();
    }
  }

  /// Write the interface-freeze spec for this iOS release build and
  /// return a function that adds the front-end flags for it, or null
  /// (with an error logged) when the freeze cannot be set up — building
  /// without it would ship a baseline that later patches cannot call
  /// reliably, so that is a hard failure, not a warning.
  ///
  /// The spec lists only libraries the compile actually contains
  /// (discovered via a fast front-end pre-pass), because a listed
  /// library that is absent from the compile fails the whole build.
  Future<List<String> Function(List<String>)?> _prepareIosInterfaceFreeze(
      CodePushBuildService buildService) async {
    final projectRoot = Directory.current.path;
    final pubspec = File('$projectRoot/pubspec.yaml');
    final packageName = pubspec.existsSync()
        ? CodePushBuildService.parsePubspecName(pubspec.readAsStringSync())
        : null;
    if (packageName == null) {
      _logger.err(
        'Could not read the package name from pubspec.yaml; cannot '
        'prepare the iOS release build.',
      );
      return null;
    }
    final specDir = Directory('$projectRoot/build/codepush')
      ..createSync(recursive: true);
    final specPath = '${specDir.path}/dynamic_interface.yaml';
    final reportPath = '${specDir.path}/dynamic_interface_report.json';
    if (specPath.contains(',') || reportPath.contains(',')) {
      _logger.err(
        'The project path contains a comma, which the build toolchain '
        'cannot pass through. Move the project to a comma-free path.',
      );
      return null;
    }
    final progress = _logger.progress('Analyzing app libraries');
    final closure = await buildService.discoverCompileClosure(
      targetPath: 'lib/main.dart',
      workDirPath: specDir.path,
    );
    if (closure == null) {
      progress.fail('Could not analyze the app for the release build');
      return null;
    }
    final appLibraries = CodePushBuildService.appLibrariesFromClosure(
      closurePaths: closure,
      projectRoot: projectRoot,
      packageName: packageName,
      onSkip: (path, reason) => _logger.warn('Not frozen ($reason): $path'),
    );
    final flutterLibraries =
        CodePushBuildService.flutterLibrariesFromClosure(closure);
    // The compile target lib/main.dart is always in its own closure, so
    // an empty mapping means the path-prefix match failed, not that the
    // app has no libraries.
    if (appLibraries.isEmpty) {
      _logger.warn(
        'No app libraries were mapped into the interface freeze — the '
        'app\'s own public shapes will not be preserved. This usually '
        'means the project path shape is unexpected; please report it.',
      );
    }
    File(specPath).writeAsStringSync(
      CodePushBuildService.buildIosInterfaceFreezeYaml(
        flutterLibraries: flutterLibraries,
        appLibraries: appLibraries,
      ),
    );
    progress.complete(
      'Interface: ${appLibraries.length} app + ${flutterLibraries.length} '
      'framework libraries',
    );
    return (args) => CodePushBuildService.withIosReleaseFrontEndOptions(
          args,
          freezeSpecPath: specPath,
          reportPath: reportPath,
        );
  }

  void _saveIosBaselineApp({required String baselineId}) {
    const source = 'build/ios/iphoneos/Runner.app';
    const dest = 'build/codepush/baseline/Runner.app';

    final sourceDir = Directory(source);
    if (!sourceDir.existsSync()) {
      _logger.detail('No built Runner.app to save.');
      return;
    }

    // Remove any previous saved baseline.
    final destDir = Directory(dest);
    if (destDir.existsSync()) {
      destDir.deleteSync(recursive: true);
    }
    destDir.parent.createSync(recursive: true);

    // Copy recursively.
    final result = Process.runSync('cp', ['-R', source, dest]);
    if (result.exitCode != 0) {
      _logger.warn('Could not save baseline app to $dest');
      return;
    }

    _logger.info('');
    _logger.success('Saved baseline app: $dest');
    _logger.info('  Embedded baseline ID: $baselineId');
    _logger.info(
      '  If installing manually on device, re-sign the saved '
      'app bundle recursively after any framework repair.',
    );
  }
}
