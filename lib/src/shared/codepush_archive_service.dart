import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_compile/src/shared/interface_freeze_constants.dart';
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
///       dynamic_interface.yaml      (optional, the interface freeze the
///                                    baseline was built with — intent)
///       dynamic_interface_report.json (optional, the compiler's own
///                                    account of what it guarded — evidence)
///       manifest.json               (see below)
///
/// `manifest.json` keys (format v2): `archive_format_version`,
/// `release_id`, `baseline_id`, `platform`, `framework_sha256`,
/// `app_framework_sha256`, `runner_binary_sha256`, `has_dsym`,
/// `has_interface_spec` (copy outcome), `interface_spec_source_name`
/// (the content-addressed basename that entered the build's option
/// string — the join key against env-hash build directories; null
/// when no spec was attested), `has_interface_report`
/// (tri-state copy outcome: true = archived, false = known absent —
/// no freeze this run, the copy failed, or the report was produced
/// and then lost, null = the compiler wrote none this build —
/// interpret via `interface_spec_change`), `interface_spec_change`
/// (`"changed"` | `"unchanged"` | `"unknown"`, null when no spec was
/// attested: `unchanged` makes a null report benign — a warm rebuild
/// reusing the identical spec — while `changed` means the compiler
/// should have run and a null report suggests SDK drift),
/// `has_extendable_widgets` (attestation — was
/// guarding requested and emitted into the spec), `build_date`,
/// `fcp_version`. In a v1 manifest the v2 keys are absent, which means
/// UNKNOWN, not false. Nothing else in the repo documents this
/// manifest; update this block when the key set changes.
///
/// The archive lets a future device replay reinstall the exact app
/// bundle that was used to produce a given release, without depending
/// on the CI/build cache having survived.
///
/// To keep the archive out of `git status` noise, the service appends
/// `.fcp-archive/` to the repo's local-only `.git/info/exclude` on
/// first use.  No project-level `.gitignore` is touched.
class CodePushArchiveService {
  CodePushArchiveService({
    required Logger logger,
    Directory? projectDir,
  })  : _logger = logger,
        _projectDir = projectDir ?? Directory.current;

  // v2: adds has_interface_spec, has_interface_report,
  // has_extendable_widgets, interface_spec_source_name and
  // interface_spec_change. The bump is what lets a reader distinguish
  // "guarding was off" from "this manifest predates the keys".
  static const int _archiveFormatVersion = 2;
  static const String _archiveDirName = '.fcp-archive';
  static const String _excludeRule = '.fcp-archive/';

  final Logger _logger;
  final Directory _projectDir;

  /// Archives the iOS baseline produced by the current `release --build`
  /// run. Returns `true` if the archive was written, `false` if a
  /// non-fatal precondition was missing (e.g., no built Runner.app).
  ///
  /// [interfaceSpecPath] is the interface-freeze spec written by THIS
  /// run, or null when the run produced none (freeze skipped or
  /// failed). The archive copies only what the caller attests to —
  /// keying on a file merely existing on disk would claim a previous
  /// run's spec as this release's. [interfaceReportPath] is the
  /// compiler's own report of what it guarded, written by the build
  /// under the same attestation; [interfaceReportWasProduced] says
  /// whether the caller observed it after the build, so a
  /// produced-then-lost report records false (known problem) while a
  /// never-produced one (reused compile) records null (unknown).
  /// [interfaceSpecExtendable] records whether the spec marked the
  /// widget bases extendable; it is attestation, not copy outcome, so
  /// the manifest can still answer "was guarding on?" when the
  /// optional copies themselves failed. [interfaceSpecChange] is the
  /// writer's spec-change verdict, stored so a null report stays
  /// interpretable months later (see the class doc).
  ///
  /// Errors are logged but never thrown — archiving is best-effort and
  /// must not fail an otherwise successful release.
  bool archiveIosRelease({
    required String releaseId,
    required String baselineId,
    required String fcpVersion,
    String? interfaceSpecPath,
    String? interfaceReportPath,
    bool interfaceReportWasProduced = false,
    bool interfaceSpecExtendable = false,
    InterfaceSpecChange? interfaceSpecChange,
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
      final cpRunner =
          Process.runSync('cp', ['-R', runnerApp.path, runnerCopy]);
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
        final cpDsym = Process.runSync(
          'cp',
          ['-R', dsymSource.path, dsymCopy],
        );
        if (cpDsym.exitCode == 0) {
          archivedDsym = true;
        } else {
          _logger.detail('Could not archive dSYM: ${cpDsym.stderr}');
        }
      }

      // The freeze spec answers "did this baseline have widget guarding,
      // and over which libraries?" — the first question when a patch
      // fails on a device months later. Optional like the dSYM: its
      // failure must not discard the app-bundle archive.
      final archivedSpec = _copyOptionalArtifact(
        label: 'interface spec',
        sourcePath: interfaceSpecPath,
        destPath: '${releaseDir.path}/$kInterfaceSpecFilename',
      );
      // The report is the compiler's evidence that the spec was
      // consumed — without it the manifest only restates intent.
      // Tri-state: only the front end writes the report, and a warm
      // rebuild (cached kernel step) legitimately writes none — that is
      // UNKNOWN (null), not false; false means known-not-archived (no
      // freeze this run, or the copy itself failed).
      final bool? archivedReport;
      if (interfaceReportPath == null) {
        archivedReport = false;
      } else if (!File(interfaceReportPath).existsSync()) {
        if (interfaceReportWasProduced) {
          // Observed after the build, gone now: a known problem, not
          // an unknown.
          _logger.detail(
            'Interface report was produced but is now missing: '
            '$interfaceReportPath',
          );
          archivedReport = false;
        } else {
          // The compiler wrote none this build. WHY is not this
          // method's to assert — interface_spec_change in the manifest
          // carries the interpretation (unchanged = warm rebuild,
          // benign; changed = the compiler should have run, suspect
          // SDK drift; unknown = nothing to compare), and the CLI
          // surfaced the same split at build time.
          archivedReport = null;
        }
      } else {
        archivedReport = _copyOptionalArtifact(
          label: 'interface report',
          sourcePath: interfaceReportPath,
          destPath: '${releaseDir.path}/$kInterfaceReportFilename',
        );
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
        'has_interface_spec': archivedSpec,
        // The content-addressed name that entered the build's option
        // string — the join key against .dart_tool/flutter_build
        // env-hash directories months later.
        'interface_spec_source_name': interfaceSpecPath == null
            ? null
            : File(interfaceSpecPath).uri.pathSegments.last,
        'has_interface_report': archivedReport,
        // Interprets a null report: unchanged = warm rebuild (benign),
        // changed = the compiler should have run, unknown = nothing to
        // compare. Null when no spec was attested.
        'interface_spec_change':
            interfaceSpecPath == null ? null : interfaceSpecChange?.name,
        'has_extendable_widgets': interfaceSpecExtendable,
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
      _logger.detail(
        '  Interface spec included: $archivedSpec '
        '(extendable: $interfaceSpecExtendable)',
      );
      _logger.detail(
        '  Interface report included: '
        '${archivedReport ?? 'unknown (not produced this build)'}',
      );
      return true;
    } catch (e, st) {
      _logger.warn('Archive step skipped: $e');
      _logger.detail('$st');
      return false;
    }
  }

  /// Copy an attested optional artifact into the archive, non-fatally:
  /// a missing source leaves a breadcrumb (it is distinguishable from
  /// "none attested"), and a copy failure must never discard the
  /// app-bundle archive around it. Returns whether the copy happened.
  bool _copyOptionalArtifact({
    required String label,
    required String? sourcePath,
    required String destPath,
  }) {
    if (sourcePath == null) return false;
    if (!File(sourcePath).existsSync()) {
      _logger.detail('Attested $label is missing: $sourcePath');
      return false;
    }
    try {
      File(sourcePath).copySync(destPath);
      return true;
    } on FileSystemException catch (e) {
      _logger.detail('Could not archive the $label: $e');
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
      final existing =
          excludeFile.existsSync() ? excludeFile.readAsStringSync() : '';
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
      final result = Process.runSync(
        'git',
        ['-C', _projectDir.path, 'rev-parse', '--git-dir'],
      );
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
