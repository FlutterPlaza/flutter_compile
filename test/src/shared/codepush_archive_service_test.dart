import 'dart:convert';
import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_archive_service.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:test/test.dart';

void main() {
  group('CodePushArchiveService.archiveIosRelease', () {
    late Directory projectDir;
    late Logger logger;
    late CodePushArchiveService service;

    setUp(() {
      projectDir = Directory.systemTemp.createTempSync('fcp-archive-test-');
      logger = Logger(level: Level.quiet);
      service = CodePushArchiveService(logger: logger, projectDir: projectDir);
    });

    tearDown(() {
      if (projectDir.existsSync()) {
        projectDir.deleteSync(recursive: true);
      }
    });

    void writeBaselineApp({
      String flutterFrameworkContents = 'fake-flutter-binary',
      String appFrameworkContents = 'fake-app-aot-binary',
      String runnerBinaryContents = 'fake-runner-binary',
    }) {
      final baselineApp = Directory(
        '${projectDir.path}/build/codepush/baseline/Runner.app',
      );
      Directory(
        '${baselineApp.path}/Frameworks/Flutter.framework',
      ).createSync(recursive: true);
      Directory(
        '${baselineApp.path}/Frameworks/App.framework',
      ).createSync(recursive: true);
      File(
        '${baselineApp.path}/Frameworks/Flutter.framework/Flutter',
      ).writeAsStringSync(flutterFrameworkContents);
      File(
        '${baselineApp.path}/Frameworks/App.framework/App',
      ).writeAsStringSync(appFrameworkContents);
      File(
        '${baselineApp.path}/Runner',
      ).writeAsStringSync(runnerBinaryContents);
      File('${baselineApp.path}/Info.plist').writeAsStringSync('plist');
    }

    void writeDsym() {
      final dsym = Directory(
        '${projectDir.path}/build/ios/iphoneos/Runner.app.dSYM',
      );
      dsym.createSync(recursive: true);
      File('${dsym.path}/marker').writeAsStringSync('dsym');
    }

    void initGitRepo() {
      final result = Process.runSync('git', [
        '-C',
        projectDir.path,
        'init',
        '-q',
      ]);
      if (result.exitCode != 0) {
        fail('git init failed: ${result.stderr}');
      }
    }

    test('returns false when no baseline app is present', () {
      final ok = service.archiveIosRelease(
        releaseId: 'rel-1',
        baselineId: 'base-1',
        fcpVersion: '0.0.0',
      );
      expect(ok, isFalse);
      expect(
        Directory('${projectDir.path}/.fcp-archive').existsSync(),
        isFalse,
      );
    });

    test('archives Runner.app and writes a manifest with all three SHAs', () {
      writeBaselineApp();

      final ok = service.archiveIosRelease(
        releaseId: 'rel-2',
        baselineId: 'base-2',
        fcpVersion: '0.19.99',
      );

      expect(ok, isTrue);
      final releaseDir = Directory('${projectDir.path}/.fcp-archive/rel-2');
      expect(releaseDir.existsSync(), isTrue);
      expect(
        File('${releaseDir.path}/Runner.app/Info.plist').existsSync(),
        isTrue,
      );
      expect(
        File(
          '${releaseDir.path}/Runner.app/Frameworks/Flutter.framework/Flutter',
        ).existsSync(),
        isTrue,
      );

      final manifest =
          jsonDecode(
                File('${releaseDir.path}/manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(manifest['archive_format_version'], 1);
      expect(manifest['release_id'], 'rel-2');
      expect(manifest['baseline_id'], 'base-2');
      expect(manifest['fcp_version'], '0.19.99');
      expect(manifest['platform'], 'ios-arm64');
      expect(manifest['has_dsym'], isFalse);
      expect((manifest['framework_sha256'] as String).length, 64);
      expect((manifest['app_framework_sha256'] as String).length, 64);
      expect((manifest['runner_binary_sha256'] as String).length, 64);
      expect(manifest['build_date'], isA<String>());
    });

    test('archives the dSYM when present and records it in manifest', () {
      writeBaselineApp();
      writeDsym();

      final ok = service.archiveIosRelease(
        releaseId: 'rel-3',
        baselineId: 'base-3',
        fcpVersion: '0.0.0',
      );

      expect(ok, isTrue);
      final releaseDir = Directory('${projectDir.path}/.fcp-archive/rel-3');
      expect(
        Directory('${releaseDir.path}/Runner.app.dSYM').existsSync(),
        isTrue,
      );
      final manifest =
          jsonDecode(
                File('${releaseDir.path}/manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(manifest['has_dsym'], isTrue);
    });

    test('does NOT write a project-level .gitignore inside the archive', () {
      writeBaselineApp();

      service.archiveIosRelease(
        releaseId: 'rel-4',
        baselineId: 'base-4',
        fcpVersion: '0.0.0',
      );

      expect(
        File('${projectDir.path}/.fcp-archive/.gitignore').existsSync(),
        isFalse,
      );
    });

    test('appends .fcp-archive/ to .git/info/exclude in a git repo', () {
      initGitRepo();
      writeBaselineApp();

      service.archiveIosRelease(
        releaseId: 'rel-5',
        baselineId: 'base-5',
        fcpVersion: '0.0.0',
      );

      final excludeFile = File('${projectDir.path}/.git/info/exclude');
      expect(excludeFile.existsSync(), isTrue);
      final lines = excludeFile
          .readAsStringSync()
          .split('\n')
          .map((l) => l.trim())
          .toList();
      expect(lines.contains('.fcp-archive/'), isTrue);
    });

    test('does not duplicate the exclude entry on re-runs', () {
      initGitRepo();
      writeBaselineApp();

      service.archiveIosRelease(
        releaseId: 'rel-6a',
        baselineId: 'base-6a',
        fcpVersion: '0.0.0',
      );
      service.archiveIosRelease(
        releaseId: 'rel-6b',
        baselineId: 'base-6b',
        fcpVersion: '0.0.0',
      );

      final excludeContents = File(
        '${projectDir.path}/.git/info/exclude',
      ).readAsStringSync();
      final occurrences =
          '\n$excludeContents\n'.split('\n.fcp-archive/').length - 1;
      expect(occurrences, 1);
    });

    test('does not crash outside a git repo', () {
      writeBaselineApp();

      final ok = service.archiveIosRelease(
        releaseId: 'rel-7',
        baselineId: 'base-7',
        fcpVersion: '0.0.0',
      );

      expect(ok, isTrue);
      // No .git directory was created.
      expect(Directory('${projectDir.path}/.git').existsSync(), isFalse);
    });

    test('overwrites an existing release archive on re-run', () {
      writeBaselineApp(flutterFrameworkContents: 'first-run-binary');
      service.archiveIosRelease(
        releaseId: 'rel-8',
        baselineId: 'base-8',
        fcpVersion: '0.0.0',
      );

      writeBaselineApp(flutterFrameworkContents: 'second-run-binary');
      final ok = service.archiveIosRelease(
        releaseId: 'rel-8',
        baselineId: 'base-8',
        fcpVersion: '0.0.0',
      );

      expect(ok, isTrue);
      final framework = File(
        '${projectDir.path}/.fcp-archive/rel-8/Runner.app/Frameworks/'
        'Flutter.framework/Flutter',
      );
      expect(framework.readAsStringSync(), 'second-run-binary');
    });

    test('all three SHAs match their respective binaries', () {
      writeBaselineApp(
        flutterFrameworkContents: 'flutter-payload-9',
        appFrameworkContents: 'app-payload-9',
        runnerBinaryContents: 'runner-payload-9',
      );
      service.archiveIosRelease(
        releaseId: 'rel-9',
        baselineId: 'base-9',
        fcpVersion: '0.0.0',
      );

      final manifest =
          jsonDecode(
                File(
                  '${projectDir.path}/.fcp-archive/rel-9/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      // Pre-computed sha256 of the literal bytes.
      expect(
        manifest['framework_sha256'],
        '140f8a4681b477164a160ef9e74fc155abb28417461bc364ae7b229356492278',
      );
      expect(
        manifest['app_framework_sha256'],
        '2e7a32b782df603a39a9240da00bb9a3b6b8c354449e078b712266ae2679d060',
      );
      expect(
        manifest['runner_binary_sha256'],
        'ed2fa5f633724e4c7833dac400a5c744a3c76d9e962b6802eb814cfaf20956e7',
      );
    });
  });
}
