import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';

/// Saves a copy of the iOS baseline app bundle, the embedded Flutter
/// framework SHA, and the dSYM (when present) into a per-release
/// archive directory next to the project.
///
/// Layout:
///   `<projectDir>/.fcp-archive/`
///     `<release_id>/`
///       Runner.app/                 (full bundle, ready to re-sign + install)
///       Runner.app.dSYM/            (optional, when build emitted one)
///       manifest.json               (release/baseline ids, framework SHA, etc.)
///
/// The archive lets a future device replay reinstall the exact app
/// bundle that was used to produce a given release, without depending
/// on the CI/build cache having survived.
///
/// To keep the archive out of `git status` noise, the service appends
/// `.fcp-archive/` to the repo's local-only `.git/info/exclude` on
/// first use.  No project-level `.gitignore` is touched.
class CodePushArchiveService {
  CodePushArchiveService({required Logger logger, Directory? projectDir})
    : _logger = logger,
      _projectDir = projectDir ?? Directory.current;

  static const int _archiveFormatVersion = 1;
  static const String _archiveDirName = '.fcp-archive';
  static const String _excludeRule = '.fcp-archive/';

  final Logger _logger;
  final Directory _projectDir;

  /// Archives the iOS baseline produced by the current `release --build`
  /// run. Returns `true` if the archive was written, `false` if a
  /// non-fatal precondition was missing (e.g., no built Runner.app).
  ///
  /// Errors are logged but never thrown — archiving is best-effort and
  /// must not fail an otherwise successful release.
  bool archiveIosRelease({
    required String releaseId,
    required String baselineId,
    required String fcpVersion,
  }) {
    try {
      final runnerApp = Directory(
        '${_projectDir.path}/build/codepush/baseline/Runner.app',
      );
      if (!runnerApp.existsSync()) {
        _logger.detail('No saved baseline app to archive.');
        return false;
      }

      final flutterFramework = File(
        '${runnerApp.path}/Frameworks/Flutter.framework/Flutter',
      );
      final appFramework = File(
        '${runnerApp.path}/Frameworks/App.framework/App',
      );
      final runnerBinary = File('${runnerApp.path}/Runner');

      final archiveRoot = Directory('${_projectDir.path}/$_archiveDirName');
      final releaseDir = Directory('${archiveRoot.path}/$releaseId');
      if (!archiveRoot.existsSync()) {
        archiveRoot.createSync(recursive: true);
      }
      _ensureGitExclude();
      if (releaseDir.existsSync()) {
        releaseDir.deleteSync(recursive: true);
      }
      releaseDir.createSync(recursive: true);

      final runnerCopy = '${releaseDir.path}/Runner.app';
      final cpRunner = Process.runSync('cp', [
        '-R',
        runnerApp.path,
        runnerCopy,
      ]);
      if (cpRunner.exitCode != 0) {
        _logger.warn('Could not archive Runner.app: ${cpRunner.stderr}');
        return false;
      }

      final dsymSource = Directory(
        '${_projectDir.path}/build/ios/iphoneos/Runner.app.dSYM',
      );
      var archivedDsym = false;
      if (dsymSource.existsSync()) {
        final dsymCopy = '${releaseDir.path}/Runner.app.dSYM';
        final cpDsym = Process.runSync('cp', ['-R', dsymSource.path, dsymCopy]);
        if (cpDsym.exitCode == 0) {
          archivedDsym = true;
        } else {
          _logger.detail('Could not archive dSYM: ${cpDsym.stderr}');
        }
      }

      final frameworkSha = _sha256OfFile(flutterFramework);
      final appFrameworkSha = _sha256OfFile(appFramework);
      final runnerBinarySha = _sha256OfFile(runnerBinary);
      final manifest = <String, dynamic>{
        'archive_format_version': _archiveFormatVersion,
        'release_id': releaseId,
        'baseline_id': baselineId,
        'platform': 'ios-arm64',
        'framework_sha256': frameworkSha,
        'app_framework_sha256': appFrameworkSha,
        'runner_binary_sha256': runnerBinarySha,
        'has_dsym': archivedDsym,
        'build_date': DateTime.now().toUtc().toIso8601String(),
        'fcp_version': fcpVersion,
      };
      File('${releaseDir.path}/manifest.json').writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
      );

      _logger.success('Archived release: ${releaseDir.path}');
      _logger.detail(
        '  Flutter framework SHA-256: ${frameworkSha ?? "<unavailable>"}',
      );
      _logger.detail(
        '  App framework SHA-256:     ${appFrameworkSha ?? "<unavailable>"}',
      );
      _logger.detail(
        '  Runner binary SHA-256:     ${runnerBinarySha ?? "<unavailable>"}',
      );
      _logger.detail('  dSYM included: $archivedDsym');
      return true;
    } catch (e, st) {
      _logger.warn('Archive step skipped: $e');
      _logger.detail('$st');
      return false;
    }
  }

  /// Ensures `.fcp-archive/` is listed in `.git/info/exclude` so the
  /// archive doesn't appear in `git status`.  Local-only — never edits
  /// the project's tracked `.gitignore`.  Silent no-op if the project
  /// isn't inside a git repo or if `git` is unavailable.
  void _ensureGitExclude() {
    final gitDir = _findGitDir();
    if (gitDir == null) return;
    try {
      final infoDir = Directory('$gitDir/info');
      if (!infoDir.existsSync()) {
        infoDir.createSync(recursive: true);
      }
      final excludeFile = File('${infoDir.path}/exclude');
      final existing = excludeFile.existsSync()
          ? excludeFile.readAsStringSync()
          : '';
      final present = existing.split('\n').any((line) {
        final trimmed = line.trim();
        return trimmed == _excludeRule ||
            trimmed == '/$_excludeRule' ||
            trimmed == '.fcp-archive';
      });
      if (present) return;

      final needsLeadingNewline =
          existing.isNotEmpty && !existing.endsWith('\n');
      excludeFile.writeAsStringSync(
        '$existing${needsLeadingNewline ? '\n' : ''}$_excludeRule\n',
      );
      _logger.detail('Added $_excludeRule to .git/info/exclude');
    } catch (e) {
      _logger.detail('Could not update .git/info/exclude: $e');
    }
  }

  String? _findGitDir() {
    try {
      final result = Process.runSync('git', [
        '-C',
        _projectDir.path,
        'rev-parse',
        '--git-dir',
      ]);
      if (result.exitCode != 0) return null;
      final raw = (result.stdout as String).trim();
      if (raw.isEmpty) return null;
      if (raw.startsWith('/')) return raw;
      return '${_projectDir.path}/$raw';
    } catch (_) {
      return null;
    }
  }

  String? _sha256OfFile(File file) {
    if (!file.existsSync()) return null;
    return sha256.convert(file.readAsBytesSync()).toString();
  }
}
