import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_compile/src/commands/codepush_commands/_codepush_shared_args.dart';
import 'package:flutter_compile/src/shared/android_baseline_yaml.dart';
import 'package:flutter_compile/src/shared/codepush_archive_service.dart';
import 'package:flutter_compile/src/shared/codepush_artifact_manager.dart';
import 'package:flutter_compile/src/shared/codepush_build_service.dart';
import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/exception.dart';
import 'package:flutter_compile/src/shared/interface_freeze_constants.dart'
    as freeze_files;
import 'package:flutter_compile/src/shared/ios_baseline_plist.dart';
import 'package:flutter_compile/src/version.dart';
import 'package:mason_logger/mason_logger.dart';

/// The warning for `--no-interface-freeze`.
///
/// Names the ONE flag combination whose effect is otherwise invisible:
/// `--extendable-widgets` rides on the freeze — the extendable section
/// is part of the spec the freeze writes — so with the freeze off the
/// guarding flag is silently inert, defaults-on and all. Nothing fails
/// at build time; the cost lands on a device, the first time a patch
/// declares a new widget class against a baseline that cannot dispatch
/// it. A second warning for the combination would be one nobody reads,
/// so the clause lives inside the warning that already fires.
const String kInterfaceFreezeDisabledWarning =
    'Interface freeze disabled (--no-interface-freeze): this release may '
    'not be reliably patchable — including the widget guarding that lets '
    'patches add new screens, which is written as part of the freeze and '
    'is inert without it (--extendable-widgets has no effect here).';

class CodePushReleaseSubCommand extends Command<int> {
  CodePushReleaseSubCommand(
    this._logger, {
    CodePushBuildService? buildService,
    CodePushArchiveService? archiveService,
  })  : _injectedBuildService = buildService,
        _injectedArchiveService = archiveService {
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
        'extendable-widgets',
        defaultsTo: true,
        help: 'Allow patches to declare new StatelessWidget / '
            'StatefulWidget / State subclasses in the built iOS app by '
            'guarding dispatch on those base classes. Disabling removes '
            'that guarding (and its dispatch cost) — patches that add '
            'new screens will fail on such a release.',
      )
      ..addFlag(
        'interface-freeze',
        defaultsTo: true,
        help: 'Preserve public call shapes in the built iOS app so '
            'later patches can call them reliably. Disable only to '
            'work around a build issue: a release built with '
            '--no-interface-freeze may not be reliably patchable.',
      )
      ..addFlag(
        'allow-missing-baseline',
        help: 'Create an iOS release without a baseline identity. Devices '
            'running modern SDKs will never match it — special cases only.',
        negatable: false,
      );
  }

  final Logger _logger;

  /// Test seam: a build service injected by tests; production
  /// construction happens in [run].
  final CodePushBuildService? _injectedBuildService;

  /// Test seam: an archive service injected by tests; production
  /// construction happens in [archiveIosBaseline].
  final CodePushArchiveService? _injectedArchiveService;

  /// The interface spec written by THIS run's freeze preparation (path,
  /// the front-end report path the build was told to write, and whether
  /// widget bases were marked extendable), for the archive step. Null
  /// when the freeze was skipped or failed, so the archive never claims
  /// a leftover spec or report from a previous run.
  /// Public for tests (no meta dependency for @visibleForTesting).
  ({
    String path,
    String reportPath,
    bool extendable,
    freeze_files.InterfaceSpecChange specChange
  })? writtenInterfaceSpec;

  /// Whether the front end's report was observed on disk after the
  /// build ([checkInterfaceReportAfterBuild]); lets the archive tell a
  /// report that was produced-then-lost apart from one the compiler
  /// never wrote. Public for tests.
  bool interfaceReportObservedAfterBuild = false;

  /// Post-build check: surface, at default visibility, whether the
  /// compiler wrote its interface report — the evidence side of the
  /// freeze. A reused (cache-hit) compile writes none; that is safe,
  /// because the spec filename is content-addressed, so a reused
  /// compile can only pair with an IDENTICAL spec — but the operator
  /// still deserves to see that this build produced no fresh evidence.
  /// Public for tests ([run] cannot be cheaply exercised).
  void checkInterfaceReportAfterBuild() {
    final spec = writtenInterfaceSpec;
    if (spec == null) return;
    interfaceReportObservedAfterBuild = File(spec.reportPath).existsSync();
    if (!interfaceReportObservedAfterBuild) {
      // Lead with what the evidence supports: `changed` is the one
      // state where compile reuse cannot explain the missing report.
      // Level split: `unchanged` is the healthy repeat-build case (a
      // cache hit on an identical spec), so it must not cry warn — a
      // warn that fires on every CI retry stops meaning anything.
      final log = spec.specChange == freeze_files.InterfaceSpecChange.unchanged
          ? _logger.detail
          : _logger.warn;
      log(switch (spec.specChange) {
        freeze_files.InterfaceSpecChange.changed =>
          'No interface report was found at ${spec.reportPath} after '
              'the build, and the interface spec changed this run — '
              'compile reuse does not usually explain that. If your '
              'Flutter SDK is newer than this fcp version supports, '
              'the compiler may not write the report where fcp '
              'expects it. The archive records the report as unknown.',
        freeze_files.InterfaceSpecChange.unchanged =>
          'No interface report was found at ${spec.reportPath} after '
              'the build. Likeliest cause: an unchanged compile was '
              'reused — safe, because the spec filename is '
              'content-addressed, so a reused compile can only pair '
              'with this exact spec. The archive records the report '
              'as unknown.',
        freeze_files.InterfaceSpecChange.unknown =>
          'No interface report was found at ${spec.reportPath} after '
              'the build, and fcp cannot tell whether the compile was '
              'reused (no previous spec to compare against). If your '
              'Flutter SDK is newer than this fcp version supports, '
              'the compiler may not write the report where fcp '
              'expects it. The archive records the report as unknown.',
      });
    }
  }

  /// Whether an explicit `--snapshot` names bytes OTHER than this
  /// run's build output — ONE read shared by the attestation, the
  /// baseline-app save, and the archive gate, so the three records
  /// cannot disagree by drift. The flag alone is not the question:
  /// a CI script that passes the built binary's own path explicitly
  /// (the exact spelling the command's guidance teaches) is still
  /// uploading the frozen build and keeps its attestation, saved
  /// app, and archive. Trimmed like every boundary read. An
  /// undecidable comparison resolves to TRUE (foreign): never
  /// attest or archive on a guess — the closed-but-safe direction,
  /// since the cost is a skipped record, not a rejection. Public
  /// for tests; reads its own args.
  bool get usedExplicitSnapshot => snapshotIsForeignTo();

  /// Implementation of [usedExplicitSnapshot] with a root seam so
  /// the PHYSICAL tier is testable without touching the checkout
  /// (the default side is cwd-anchored in production).
  bool snapshotIsForeignTo({String? projectRootOverride}) {
    final defaultAppPath = projectRootOverride == null
        ? kDefaultBuiltIosAppPath
        : '$projectRootOverride/$kDefaultBuiltIosAppPath';
    final raw = argResults?['snapshot'] as String?;
    // Blankness classified on the trimmed value; the PATH itself is
    // deliberately untrimmed so this classifies the same string
    // run() stats and uploads (the path-flag rule).
    if (raw == null || raw.trim().isEmpty) return false;
    final appDir = builtIosAppDirFromBinaryPath(raw);
    if (appDir == null) return true;
    // PHYSICAL resolution on both sides: lexical normalization
    // cannot see through symlinked prefixes ($PWD is logical, getcwd
    // physical — macOS /var -> /private/var), and here a wrong
    // 'foreign' answer costs four records, three permanently. Both
    // paths exist when this matters (the snapshot was stat'ed, the
    // default exists whenever --build ran on iOS); anything
    // undecidable still resolves foreign via the catch.
    try {
      return Directory(appDir).resolveSymbolicLinksSync() !=
          Directory(defaultAppPath).resolveSymbolicLinksSync();
    } on FileSystemException {
      // A side does not exist (e.g. --snapshot without --build, where
      // no default output was produced): physical resolution is
      // impossible, so fall back to lexical normalization — it still
      // equates the plain spellings, and the records this getter
      // gates are inert without a build anyway.
      try {
        String norm(String p) =>
            File(p).absolute.uri.normalizePath().toFilePath();
        return norm(appDir) != norm(defaultAppPath);
      } catch (_) {
        return true;
      }
    } catch (_) {
      return true;
    }
  }

  /// Existence check for an explicit --snapshot. Without --build,
  /// nothing will create a missing path, so it is an argument
  /// mistake that must cost an exit 64 here, never a late exit 70
  /// after resolution work (blankness is [blankArgError]'s). With
  /// --build, a missing FILE defers to [snapshotPreBuildWarning] —
  /// a guess about what the build is about to create must never
  /// reject a run that would have succeeded — but an existing
  /// DIRECTORY is a fact, and outside build/ no build replaces one
  /// with a file, so that one case rejects even with --build
  /// (under build/ it defers to the post-build stat — EXCEPT an .app
  /// bundle directory, which no build replaces with a file and which
  /// therefore rejects up front on either side of build/).
  String? snapshotArgError({
    required bool willBuild,
    String? projectRootOverride,
  }) {
    final raw = argResults?['snapshot'] as String?;
    if (raw == null || raw.trim().isEmpty) return null;
    if (File(raw).existsSync()) return null;
    if (Directory(raw).existsSync()) {
      // A directory is a FACT, not a lexical guess — and outside
      // build/ no build ever replaces one with a file, so spending
      // the build first proves nothing. Under build/ a stale
      // directory CAN be cleaned and rebuilt as a file, so that one
      // case stays with the pre-build warning + post-build stat —
      // EXCEPT an app BUNDLE directory (.app): the build recreates a
      // bundle as a DIRECTORY, never replaces it with a file, so the
      // failure is certain either side of build/ and deferring only
      // burns the build (round-19 Low).
      // Lexically normalize before the suffix test so 'Runner.app/.'
      // and 'Runner.app/./' still read as the bundle they name
      // ('Runner.app/..' correctly stays non-bundle — it names the
      // parent). Same idiom as [lexicallyUnderBuildDir].
      String bundleProbe;
      try {
        bundleProbe = File(raw).absolute.uri.normalizePath().toFilePath();
      } catch (_) {
        bundleProbe = raw;
      }
      final bundleShaped = bundleProbe
          .toLowerCase()
          .replaceAll(RegExp(r'[/\\]+$'), '')
          .endsWith('.app');
      if (!willBuild ||
          bundleShaped ||
          !lexicallyUnderBuildDir(
            raw,
            projectRootOverride: projectRootOverride,
          )) {
        return missingSnapshotCore(raw);
      }
      return null;
    }
    // With --build, every missing NON-directory path defers to the
    // post-build stat — including a dangling symlink. A dead link is
    // a fact about the LINK, not about the run: the build can create
    // the link's TARGET (a stable alias into build output resolves
    // the moment the build writes it), so an up-front rejection here
    // would fail a run that was about to succeed.
    // [snapshotPreBuildWarning] carries the dead-link caution.
    if (willBuild) return null;
    // A dangling symlink without --build IS actionable up front:
    // missingSnapshotCore already names the exact fix (restore the
    // target). The --build hint is not a guess here — the link's
    // target is readable (danglingLinkTargetsBuildDir), so say it
    // exactly when a build would in fact create the target, and
    // omit it when it wouldn't (round-19 Low).
    if (FileSystemEntity.typeSync(raw, followLinks: false) ==
        FileSystemEntityType.link) {
      if (danglingLinkTargetsBuildDir(
        raw,
        projectRootOverride: projectRootOverride,
      )) {
        // The iOS caveat rides along because this emitter runs before
        // the platform is resolved: an aliased path never yields a
        // baseline identity (the identity read does not resolve
        // links), so --build alone ends at a second exit 64 there.
        // Both remedies must include --build: this emitter only fires
        // WITHOUT it, so the link's target — and any direct path into
        // build/ — does not exist yet, and "point at the binary" alone
        // would just land at the not-found exit again.
        return '${missingSnapshotCore(raw)} The link points into '
            'build/ — the simplest fix is --build with --snapshot '
            'pointing at the binary path under build/ directly (no '
            'alias). Keeping the alias works too: pass --build so the '
            'build can create the target, and for an iOS release add '
            '--baseline-id or --allow-missing-baseline (the identity '
            'read uses the --snapshot path as given and does not '
            'resolve links).';
      }
      return missingSnapshotCore(raw);
    }
    return '${missingSnapshotCore(raw)} Check the --snapshot path — '
        'or, if you expected this run to produce the bytes to upload, '
        'pass --build.';
  }

  /// The flag-vs-built-bytes identity decision, pure and rowable
  /// (the same seam discipline as [snapshotArgError]: a rejection
  /// deserves rows). Returns null when --baseline-id raises no
  /// objection, else a statement of the contradiction — the CALLER
  /// picks the remedy (refuse; or, under --allow-missing-baseline,
  /// fall back to the embedded id when one exists, else proceed
  /// identity-less). Fires only for a --build run
  /// releasing that build's own bytes whose stamp FAILED: a
  /// successful stamp supersedes the flag, and a foreign --snapshot's
  /// identity belongs to the third-state branch. The compare is
  /// EXACT, deliberately not case-folded: an accepted flag becomes
  /// the recorded identity in ITS casing while devices present the
  /// EMBEDDED casing verbatim and the server compares exactly — a
  /// tolerant acceptance would record an id no device ever sends.
  String? baselineIdContradiction({
    required bool shouldBuild,
    required bool snapshotIsForeign,
    required String? stampedByThisBuild,
    required String? explicitFlag,
    required String? embeddedInBuiltApp,
    String? stampFailureCause,
  }) {
    if (!shouldBuild || snapshotIsForeign) return null;
    if (stampedByThisBuild != null) return null;
    // Trim BOTH sides and treat blank as absent, matching
    // resolveIosBaselineId — an empty embedded id must read as "no id"
    // (not as a present-but-empty contradiction that would record ''
    // as a real baseline_id), and a padded flag must not spuriously
    // mismatch a clean embedded id.
    final flag = explicitFlag?.trim();
    if (flag == null || flag.isEmpty) return null;
    final embeddedRaw = embeddedInBuiltApp?.trim();
    final embedded =
        (embeddedRaw == null || embeddedRaw.isEmpty) ? null : embeddedRaw;
    if (embedded != null && embedded == flag) return null;
    return embedded == null
        ? '--baseline-id names an id this build did not embed: the '
            'stamp failed '
            '(${stampFailureCause ?? 'ios/Runner/Info.plist is missing'}), '
            'so the built app carries no FCPBaselineId and a release '
            'recorded under the flag would never match a device that '
            'checks identity.'
        : '--baseline-id ($flag) contradicts the id the built '
            'app actually embeds ($embedded). Devices send the '
            'embedded id, so a release recorded under the flag would '
            'never be offered to them.';
  }

  /// Maps an iOS stamp-write/read [FileSystemException] to an
  /// operator-facing cause, structurally (by `osError.errorCode`),
  /// not lexically — same discipline as the decode split. Pure and
  /// rowable so the exception-shape→text mapping has a seam:
  /// - no OSError + a decode message → binary plist (the READ
  ///   throwing on non-UTF-8, before any temp is created);
  /// - EACCES/EPERM → the directory the temp+rename needs (or an
  ///   unreadable plist — both are "fix a permission", and naming
  ///   the directory is the one the flagship read-only-`ios/Runner/`
  ///   case actually needs). The writer resolves symlinks FIRST and
  ///   creates the temp in the RESOLVED target's parent, so when the
  ///   failing operation's own path (`e.path`) sits outside
  ///   `ios/Runner/` — the plist is a link into shared config whose
  ///   directory is read-only — the guidance names THAT directory:
  ///   telling the operator to make `ios/Runner/` writable when it
  ///   demonstrably is would send them nowhere (the restore half's
  ///   link-awareness, applied to the stamp half);
  /// - ENOSPC/EDQUOT/EROFS → a full/read-only disk, NOT permissions;
  /// - anything else → a neutral could-not-read-or-write.
  String iosStampCauseFor(FileSystemException e) {
    if (e.osError == null && e.message.contains('Failed to decode')) {
      return 'ios/Runner/Info.plist is not readable as UTF-8 text '
          '(a binary plist?)';
    }
    // EACCES/EPERM/ENOSPC/EROFS are identical on macOS and Linux;
    // EDQUOT is 69 on macOS/BSD but 122 on Linux (69 there is
    // ESRMNT), so accept both — the stamp runs before `flutter build`
    // and can hit a per-user quota in a Linux CI container.
    const eacces = 13, eperm = 1, enospc = 28, erofs = 30;
    const edquotDarwin = 69, edquotLinux = 122;
    final code = e.osError?.errorCode;
    if (code == eacces || code == eperm) {
      final linkedDir = _stampFailingDirOutsideRunner(e.path);
      if (linkedDir != null) {
        return 'the stamp needs a writable $linkedDir/ directory — '
            'ios/Runner/Info.plist resolves there through a symbolic '
            'link, so THAT directory (not ios/Runner/) is the one to '
            'make writable';
      }
      return 'the stamp needs a writable ios/Runner/ directory '
          '(not just a writable Info.plist), or the plist is '
          'unreadable — a permissions problem either way';
    }
    if (code == enospc ||
        code == erofs ||
        code == edquotDarwin ||
        code == edquotLinux) {
      return 'ios/Runner/ could not be written — no space, over a '
          'disk quota, or on a read-only mount';
    }
    return 'ios/Runner/Info.plist could not be read, or the stamp '
        'could not be written to ios/Runner/';
  }

  /// The parent directory of the failing operation's own path
  /// ([FileSystemException.path]) when it sits OUTSIDE `ios/Runner/`,
  /// else null. Structural, not a filesystem probe — the exception
  /// already names where the writer actually failed (the temp is
  /// created in the RESOLVED target's parent), so this stays pure and
  /// rowable like its caller. A bare filename or an absent path
  /// carries no directory information → null (generic text).
  static String? _stampFailingDirOutsideRunner(String? failingPath) {
    if (failingPath == null || failingPath.isEmpty) return null;
    final normalized = failingPath.replaceAll(r'\', '/');
    final cut = normalized.lastIndexOf('/');
    if (cut <= 0) return null;
    final parent = normalized.substring(0, cut);
    if (parent == 'ios/Runner' || parent.endsWith('/ios/Runner')) {
      return null;
    }
    return parent;
  }

  /// Warns when a SUCCESSFUL stamp was not consumed by the build —
  /// the built app's embedded id (what devices present) differs from
  /// or is absent versus the id this run stamped. Returns null when
  /// they agree (the normal case), else the warning. Pure and rowable:
  /// the stamp-vs-bytes check the flag-vs-bytes guard was missing.
  /// The caller then prefers the embedded id (the truth on the wire).
  String? stampConsumedWarning({
    required String? stampedByThisBuild,
    required String? embeddedInBuiltApp,
  }) {
    final stamped = stampedByThisBuild?.trim();
    if (stamped == null || stamped.isEmpty) return null;
    final embedded = embeddedInBuiltApp?.trim();
    if (embedded == stamped) return null;
    if (embedded == null || embedded.isEmpty) {
      return 'The stamp wrote ios/Runner/Info.plist but the built app '
          'embeds no FCPBaselineId — the build likely packaged a '
          'different Info.plist (a flavored INFOPLIST_FILE?). Recording '
          "this run's stamped id would create a release no device ever "
          'matches; check the Info.plist your iOS target actually uses.';
    }
    return 'The built app embeds a different FCPBaselineId ($embedded) '
        "than this run stamped ($stamped) — releasing under the "
        'embedded id, which is what devices present. (Your iOS target '
        'likely uses a plist other than ios/Runner/Info.plist.)';
  }

  /// The identity a --allow-missing-baseline run releases under when
  /// [baselineIdContradiction] fired: the id the built bytes embed
  /// (trimmed) when they carry one — strictly better than
  /// identity-less, and exactly where "drop the flag" lands — else
  /// null (proceed without identity, the outcome the opt-out names).
  /// Pure and rowable so the choice of WHICH release is created is
  /// pinned, not just whether a contradiction exists.
  String? baselineIdUnderOptOut({required String? embeddedInBuiltApp}) {
    final embedded = embeddedInBuiltApp?.trim();
    return (embedded == null || embedded.isEmpty) ? null : embedded;
  }

  /// The directory-aware core the snapshot emitters share — the
  /// pre-build gates and the post-build stat — so they cannot
  /// drift: the bundle-instead-of-binary mistake must never read as
  /// "not found" while the directory sits right there. On the
  /// --build path a bundle built THIS run is only met by the late
  /// emitter; a pre-existing .app bundle is an up-front exit in
  /// [snapshotArgError] (even under build/ — no build replaces a
  /// bundle directory with a file), and only a non-bundle directory
  /// under build/ still reaches [snapshotPreBuildWarning].
  String missingSnapshotCore(String path) {
    if (Directory(path).existsSync()) {
      return '--snapshot names a directory: $path. Pass the binary file '
          'inside it (for an iOS app bundle: '
          '<bundle>/Frameworks/App.framework/App; for a macOS app '
          'bundle: <bundle>/Contents/Frameworks/App.framework/App; '
          'for an Android build: the libapp.so for your ABI).';
    }
    // existsSync follows links, so a dangling symlink reads as
    // absent while `ls` shows the entry sitting right there — name
    // the real state instead of sending the operator typo-hunting.
    if (FileSystemEntity.typeSync(path, followLinks: false) ==
        FileSystemEntityType.link) {
      return '--snapshot names a symbolic link whose target does not '
          'exist: $path. Restore the target, or pass the real binary '
          'path.';
    }
    return 'Snapshot file not found: $path.';
  }

  /// Pre-build advisory for a --build run whose --snapshot does not
  /// exist yet: builds only write under build/, so a missing path
  /// outside it is PROBABLY a typo that would otherwise surface only
  /// after minutes of build. Warning only, by design: the
  /// containment test is lexical and case-folded, and a symlinked
  /// working directory (macOS logical $PWD vs physical getcwd) can
  /// make it guess wrong — a warning tolerates a wrong guess; a
  /// rejection must not.
  String? snapshotPreBuildWarning({String? projectRootOverride}) {
    final raw = argResults?['snapshot'] as String?;
    if (raw == null || raw.trim().isEmpty) return null;
    if (File(raw).existsSync()) return null;
    if (Directory(raw).existsSync()) {
      // Only a NON-bundle directory under build/ reaches here
      // (outside build/, and any .app bundle directory, are up-front
      // rejections in [snapshotArgError] — a directory is a fact,
      // not a guess): the build MAY clean and rebuild the path as a
      // file, so this stays a warning.
      return '${missingSnapshotCore(raw)} If the build does not '
          'replace it with a file, this release will fail after the '
          'build.';
    }
    if (lexicallyUnderBuildDir(raw, projectRootOverride: projectRootOverride)) {
      return null;
    }
    // A dead link outside build/ deserves its accurate text up front
    // too (the other two emitters get it via missingSnapshotCore) —
    // and the failure claim must match the link's TARGET: an alias
    // whose target lies under build/ resolves the moment the build
    // writes it, so certainty there would be false.
    if (FileSystemEntity.typeSync(raw, followLinks: false) ==
        FileSystemEntityType.link) {
      if (danglingLinkTargetsBuildDir(
        raw,
        projectRootOverride: projectRootOverride,
      )) {
        return '${missingSnapshotCore(raw)} The link points into '
            'build/ — if the build does not create its target, this '
            'release will fail after the build.';
      }
      return '${missingSnapshotCore(raw)} The build only writes under '
          'build/, so it will not restore this link — this release '
          'will fail after the build.';
    }
    return '--snapshot names a file that does not exist yet, and the '
        'build only writes under build/ — if $raw is mistyped, this '
        'release will fail after the build.';
  }

  /// Case-folded lexical test for "under this project's build/".
  /// Heuristic by design — symlinked working directories and
  /// case-sensitive filesystems can fool it in both directions —
  /// so callers use it only to pick the SOFTER of two outcomes
  /// (which warning text; whether an existing directory defers to
  /// the post-build stat instead of rejecting up front — the
  /// rejection itself rests on the directory FACT, and no flutter
  /// build target replaces a directory outside build/ with a file);
  /// undecidable resolves to true, the softer path. Public for
  /// tests.
  bool lexicallyUnderBuildDir(String raw, {String? projectRootOverride}) {
    try {
      final abs = File(raw).absolute.uri.normalizePath().toFilePath();
      // Directory URIs carry a trailing separator, so this is a
      // proper prefix test against build/ and not against build*.
      final buildDir = Directory(
        projectRootOverride == null ? 'build' : '$projectRootOverride/build',
      ).absolute.uri.normalizePath().toFilePath();
      return abs.toLowerCase().startsWith(buildDir.toLowerCase());
    } catch (_) {
      return true;
    }
  }

  /// Whether a dangling --snapshot symlink's TARGET lies under this
  /// project's build/ — i.e. whether the build may create it. Reads
  /// the stored target (targetSync works on a dead link) and resolves
  /// a relative one against the link's own directory, then reuses
  /// [lexicallyUnderBuildDir]'s heuristic. Picks between two WARNING
  /// texts only, so a wrong answer costs precision, never a run;
  /// unreadable resolves to false — the certain-failure text — since
  /// a link whose target can't even be read is not the build-output
  /// alias case. Public for tests.
  bool danglingLinkTargetsBuildDir(
    String raw, {
    String? projectRootOverride,
  }) {
    try {
      final target = Link(raw).targetSync();
      if (target.trim().isEmpty) return false;
      final absoluteTarget = File(target).isAbsolute
          ? target
          : '${File(raw).absolute.parent.path}/$target';
      return lexicallyUnderBuildDir(
        absoluteTarget,
        projectRootOverride: projectRootOverride,
      );
    } catch (_) {
      return false;
    }
  }

  /// Whether any component of [spelled] BELOW the project root is a
  /// symbolic link — the file itself, or a parent directory (a shared
  /// `assets/` dir is the common monorepo shape). Components at or
  /// above the root are out of scope: they resolve identically for
  /// the atomic writer and for `git checkout`, so they cannot make
  /// the recovery guidance wrong (and macOS's `/tmp` link would
  /// otherwise false-positive every temp-dir path). [stopAtDir]
  /// defaults to the current directory; public for tests.
  bool stampPathResolvesThroughLink(String spelled, {String? stopAtDir}) {
    // TOTAL by contract — this runs inside the build finally's catch
    // handler, where a second throw would REPLACE the in-flight error
    // with an unhandled exception and lose the guidance (round-17
    // L2's exact failure). The known throw source is Directory.current
    // under a deleted cwd (typeSync itself maps EVERY lstat failure —
    // ELOOP, EACCES, ENAMETOOLONG included — to notFound and never
    // throws; probed on this SDK). The catch is deliberately broader
    // than that one source: a miss here costs the guidance itself, so
    // any error falls back to false — the softer plain-git-checkout
    // text — matching the sibling helpers' convention.
    try {
      // Directory URIs carry a trailing separator, so this anchors a
      // proper prefix walk (same idiom as [lexicallyUnderBuildDir]).
      // The case-folded compare here can only WIDEN the walk (check
      // components above the intended anchor when an exotic stopAtDir
      // differs from the path only by case on a case-sensitive
      // filesystem) — in production both strings come from the same
      // absolute() resolution, so their cases always agree and the
      // fold is inert; it exists for the NTFS/default-APFS test
      // inputs, like the sibling's.
      final anchor = Directory(stopAtDir ?? Directory.current.path)
          .absolute
          .uri
          .normalizePath()
          .toFilePath();
      var p = File(spelled).absolute.uri.normalizePath().toFilePath();
      while (p.toLowerCase().startsWith(anchor.toLowerCase())) {
        if (FileSystemEntity.typeSync(p, followLinks: false) ==
            FileSystemEntityType.link) {
          return true;
        }
        final parent = File(p).parent.path;
        if (parent == p) break;
        p = parent;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// What (if anything) the stamp-consumed block owes about an
  /// explicitly passed --baseline-id, pure and rowable — the caller
  /// emits the returned text as a warning. Null when the flag is
  /// absent/blank, when it AGREES with the id the release is being
  /// recorded under (the recorded id IS the flag's value — nothing
  /// was ignored, and stampConsumedWarning already reported releasing
  /// under the embedded id), or when the no-opt-out exit will name
  /// the flag itself.
  String? baselineIdFlagNotice({
    required String? recordedId,
    required String? explicitFlag,
    required bool allowMissingBaseline,
  }) {
    final flag = explicitFlag?.trim();
    if (flag == null || flag.isEmpty) return null;
    if (recordedId != null) {
      return recordedId == flag
          ? null
          : '--baseline-id is superseded by the id the built app '
              'embeds; ignoring the flag.';
    }
    return allowMissingBaseline
        ? '--baseline-id cannot substitute for the missing embedded '
            'id and is ignored: devices send only an embedded id, and '
            'per --allow-missing-baseline this release proceeds '
            'without an identity.'
        : null;
  }

  /// Recovery guidance for a failed post-build stamp restore. The
  /// atomic writer resolves the WHOLE path through symlinks and
  /// renames at the PHYSICAL target, so when [spelled] resolves
  /// through a link — the file itself, or a linked parent directory —
  /// the stamped bytes live in the resolved file: `git checkout` of
  /// the spelled path cannot reliably clean it (a tracked leaf link
  /// restores only the link entry; a tracked parent link matches no
  /// index entry at this pathspec), so the guidance must name the
  /// physical file, or the operator is told the problem is fixed
  /// while sibling projects keep reading the stamp. Filesystem-read
  /// text selection, TOTAL (never throws, because this runs inside
  /// the finally's catch handler): the link-walk probe degrades to
  /// the softer plain-git-checkout text on error, and the target
  /// resolve degrades to the link text with a placeholder target —
  /// still naming the actionable fact (a link is in the way).
  /// Public for tests.
  String restoreFailureGuidance({
    required String spelled,
    required String stampedValueDescription,
    String? projectRootOverride,
  }) {
    if (stampPathResolvesThroughLink(
      spelled,
      stopAtDir: projectRootOverride,
    )) {
      String target;
      try {
        target = File(spelled).resolveSymbolicLinksSync();
      } on FileSystemException {
        target = "the link's target";
      }
      return '$spelled resolves through a symbolic link and the stamp '
          'was written through it: $stampedValueDescription is in '
          "$target, not at the spelled path's own entry. Clean THAT "
          'file — `git checkout -- $spelled` cannot reliably restore '
          'it, and sibling projects reading the shared file see the '
          'stamp until it is cleaned.';
    }
    return 'The file still contains $stampedValueDescription — '
        'restore it manually (e.g. git checkout -- $spelled).';
  }

  /// Pre-build advisory for --build with a foreign --snapshot: the
  /// records on the [usedExplicitSnapshot] rule (identity stamp
  /// withheld, attestation, saved app, archive) are already decided
  /// — that belongs BEFORE the minutes are spent. Advisory only,
  /// never a rejection: the records re-derive foreignness at their
  /// own sites, and a pre-build lexical answer can differ from a
  /// post-build physical one in symlinked corners. The FAIL clause
  /// is stated as certainty ONLY when the snapshot bytes already
  /// exist — only then is the pre-build plist read authoritative (a
  /// foreign path the build itself creates gets its plist, and
  /// possibly its id, only after the build).
  String? foreignSnapshotAdvisory({String? projectRootOverride}) {
    final raw = argResults?['snapshot'] as String?;
    if (raw == null || raw.trim().isEmpty) return null;
    if (Directory(raw).existsSync()) {
      // An existing directory is the wrong-path-shape mistake, not
      // foreign bytes: an .app bundle is an up-front exit in
      // [snapshotArgError], an outside-build/ directory likewise, and
      // a non-bundle directory under build/ gets the directory
      // warning + post-build stat ([missingSnapshotCore]) — a
      // foreign-bytes advisory beside any of those would mislead the
      // operator who meant this build's own output.
      return null;
    }
    if (!snapshotIsForeignTo(projectRootOverride: projectRootOverride)) {
      return null;
    }
    const base = "--snapshot names bytes other than this build's "
        'output: the interface attestation, the saved baseline app, '
        'and the per-release archive will be skipped.';
    final explicitId = (argResults?['baseline-id'] as String?)?.trim();
    if (explicitId != null && explicitId.isNotEmpty) {
      return '$base The baseline identity comes from --baseline-id.';
    }
    if (argResults?['allow-missing-baseline'] as bool? ?? false) {
      return base;
    }
    if (!File(raw).existsSync()) {
      // Missing AND outside build/: [snapshotPreBuildWarning] has
      // already named the will-fail risk for this exact path — one
      // mistake must not draw two warnings. Missing under build/
      // draws no pre-build warning, so the fail risk is named here.
      // Carve-out within the carve-out: a dead link ALIASING build
      // output gets only the conditional dead-link text from the
      // warning (the build may well create its target), so the
      // IDENTITY risk — which bites even when the target IS created,
      // because the identity read is a literal-path read that does
      // not resolve the alias — must be named here, pre-build.
      if (danglingLinkTargetsBuildDir(
        raw,
        projectRootOverride: projectRootOverride,
      )) {
        return '$base The baseline-identity read uses the --snapshot '
            'path as given and will not resolve this link, so this '
            'release will fail after the build without an identity — '
            "pass --baseline-id, or point --snapshot at this build's "
            'own binary path directly.';
      }
      return lexicallyUnderBuildDir(
        raw,
        projectRootOverride: projectRootOverride,
      )
          ? '$base If those bytes carry no readable FCPBaselineId, '
              'this release will fail after the build — pass '
              '--baseline-id to be safe.'
          : base;
    }
    final appDir = builtIosAppDirFromBinaryPath(raw);
    final bundleId = appDir == null
        ? null
        : readBaselineIdFromBuiltAppPlist(appPath: appDir);
    if (bundleId != null) {
      return "$base The baseline identity comes from the bundle's "
          'own FCPBaselineId.';
    }
    // Certainty also requires bytes this build CANNOT rewrite: a
    // stale id-less bundle under build/ may be regenerated by the
    // build below with a stamped plist, and then resolve fine.
    if (!lexicallyUnderBuildDir(
      raw,
      projectRootOverride: projectRootOverride,
    )) {
      return '$base No FCPBaselineId is readable from those bytes, '
          'so this release will FAIL after the build — pass '
          "--baseline-id, or point --snapshot at this build's own "
          'binary.';
    }
    return '$base If those bytes carry no readable FCPBaselineId, '
        'this release will fail after the build — pass '
        '--baseline-id to be safe.';
  }

  /// Build-only flags passed without --build are read by nothing —
  /// the patch command's rule, ported: an operator passing
  /// --no-extendable-widgets on a --snapshot release has good
  /// reason to believe they published an un-guarded attestation,
  /// when the record is (correctly) unknown. Returns the warning
  /// or null. Public for tests; reads its own args.
  String? buildOnlyFlagsWarning({String? resolvedPlatform}) {
    final shouldBuild = argResults?['build'] as bool? ?? false;
    // TWO lists, because the release command's axes genuinely
    // differ (the patch command's did not): the freeze flags are
    // build-only AND iOS-only, but the identity flags are read on
    // every iOS release — a no---build --snapshot release NEEDS
    // --baseline-id, and telling that flow the flag is ignored is
    // the inverse of the defect this family exists to close (read,
    // and says it isn't).
    final iosBuildOnly = <String>[
      if (argResults?.wasParsed('extendable-widgets') ?? false)
        '--[no-]extendable-widgets',
      if (argResults?.wasParsed('interface-freeze') ?? false)
        '--[no-]interface-freeze',
    ];
    final iosIdentity = <String>[
      if (((argResults?['baseline-id'] as String?) ?? '').trim().isNotEmpty)
        '--baseline-id',
      if (argResults?['allow-missing-baseline'] as bool? ?? false)
        '--allow-missing-baseline',
    ];
    if (shouldBuild) {
      // Second axis (the patch command's rule, both halves ported):
      // the iOS-shaped flags on a build for another platform are
      // read by nothing and must say so.
      if (resolvedPlatform == null || resolvedPlatform == 'ios') return null;
      final iosOnly = [...iosBuildOnly, ...iosIdentity];
      if (iosOnly.isEmpty) return null;
      return '${iosOnly.join(', ')} '
          '${iosOnly.length == 1 ? 'is' : 'are'} iOS-only; ignoring on '
          '$resolvedPlatform builds.';
    }
    final ignored = <String>[
      ...iosBuildOnly,
      if (dartDefineValues().isNotEmpty) '--dart-define',
    ];
    final identityIgnored =
        (resolvedPlatform != null && resolvedPlatform != 'ios')
            ? iosIdentity
            : const <String>[];
    final buildOnlyMsg = ignored.isEmpty
        ? null
        : '${ignored.join(', ')} '
            '${ignored.length == 1 ? 'is' : 'are'} only used together '
            'with --build; ignoring.';
    final identityMsg = identityIgnored.isEmpty
        ? null
        : '${identityIgnored.join(', ')} '
            '${identityIgnored.length == 1 ? 'is' : 'are'} only used for '
            'iOS releases; ignoring on $resolvedPlatform.';
    if (buildOnlyMsg == null && identityMsg == null) return null;
    return [buildOnlyMsg, identityMsg].whereType<String>().join(' ');
  }

  /// The --dart-define values, through the shared filter — public
  /// and arg-reading so the FILTER cannot silently revert at this
  /// command (the round-40 defect was an unobserved call site, not
  /// a diverged body). Public for tests.
  List<String> dartDefineValues() =>
      nonBlankEntries(argResults?['dart-define'] as List<String>?);

  /// Twin of the patch command's platformArgOrError — the tested
  /// wire from this command to the shared rule, so `forBuild` cannot
  /// silently flip (re-opening `release --build --platform android`)
  /// and the call cannot vanish (re-opening the silent fail-open the
  /// helper exists to close). Public for tests; reads its own args.
  (String?, String?) platformArgOrError() => normalizeCodePushPlatformArg(
        argResults?['platform'] as String?,
        forBuild: argResults?['build'] as bool? ?? false,
      );

  /// Present-but-blank rejection for this command's own boundary
  /// reads — the same contract the patch command's six flags follow
  /// (an unset CI variable must cost a re-run, never be silently
  /// re-interpreted). `--snapshot` blank is the worst of the three:
  /// run() re-reads it and blank fell through to auto-discovery,
  /// recording whatever the local build tree held as THIS version's
  /// baseline identity — id and bytes agree, so nothing ever flags
  /// it, and the app the operator actually shipped is simply never
  /// offered an update. `--version` blank silently released under
  /// the pubspec version; `--app-id` blank landed on the
  /// pass-the-flag-you-passed message. Returns the error to print,
  /// or null. A genuinely absent flag keeps its fallback (build /
  /// pubspec / stored config). `--flutter-version` blank was the
  /// quiet one: it fell through to local detection and recorded the
  /// UPLOADING machine's SDK, so every patch for the release
  /// compiled against the wrong Flutter. `--baseline-id` blank is
  /// benign in outcome (the fallback reads the id from the same
  /// bytes being uploaded) but joins the rule so the next reader
  /// can tell it was decided, not missed. Public for tests; reads
  /// its own args.
  String? blankArgError() {
    for (final flag in [
      'snapshot',
      'version',
      'app-id',
      'flutter-version',
      'baseline-id',
    ]) {
      final raw = argResults?[flag] as String?;
      if (raw != null && raw.trim().isEmpty) {
        return 'Empty --$flag value (an unset CI variable?). Pass a value, '
            'or drop the flag to use its normal fallback.';
      }
    }
    return null;
  }

  /// Parses the raw capture of a pubspec `version:` line. Strips a
  /// trailing YAML comment AND a matching surrounding quote pair —
  /// both are ordinary, legal pubspec (`version: "1.0.0+1"`,
  /// `version: 1.0.0+1 # bumped by CI`) that the end-of-line capture
  /// keeps. The YAML subtleties are this PARSER's problem;
  /// [versionValidationError] catches what is genuinely invalid.
  /// Static and pure; public for tests.
  static String pubspecVersionValue(String rawCapture) {
    // YAML starts a comment only at a '#' preceded by whitespace (or
    // line start): 'version: 1.0.0#1' is the scalar '1.0.0#1', which
    // must reach the validator's rejection — not be silently
    // truncated into a version the pubspec does not contain.
    var value = rawCapture.split(RegExp(r'(?<=^|\s)#')).first.trim();
    for (final quote in ['"', "'"]) {
      if (value.length >= 2 &&
          value.startsWith(quote) &&
          value.endsWith(quote)) {
        value = value.substring(1, value.length - 1).trim();
        break;
      }
    }
    return value;
  }

  /// Resolves the version from raw pubspec content, or null when the
  /// key is absent or valueless. The capture is confined to ONE line
  /// (`[^\S\r\n]` instead of `\s`, which crosses newlines): a
  /// valueless `version:` must fall to the no-version error, never
  /// read the NEXT line as the version. Quoting/comment subtleties
  /// are [pubspecVersionValue]'s. Static and pure; public for tests.
  static String? pubspecVersionFrom(String fileContent) {
    final match = RegExp(
      r'^version:[^\S\r\n]*(.*)$',
      multiLine: true,
    ).firstMatch(fileContent);
    if (match == null) return null;
    final value = pubspecVersionValue(match.group(1)!);
    return value.isEmpty ? null : value;
  }

  /// The pubspec content the version resolution may consult, or null
  /// when it must not or cannot. LAZY: a run that passed --version
  /// never touches the file — blankArgError already rejected blank,
  /// so a non-null flag wins; that coupling is recorded HERE, beside
  /// the gate that depends on it (deleting blankArgError's 'version'
  /// entry would change what a blank flag resolves to). GUARDED: an
  /// unreadable or non-UTF-8 pubspec degrades to null — landing on
  /// the actionable no-version error, with the cause kept at detail
  /// visibility — never an unhandled exception on a run that worked
  /// yesterday. Same rule as prepareIosInterfaceFreeze's read of
  /// this file, same seam for tests. Public for tests; reads its
  /// own args.
  String? pubspecContentForVersion({String? projectRootOverride}) {
    if (argResults?['version'] != null) return null;
    final root = projectRootOverride ?? Directory.current.path;
    final pubspecFile = File('$root/pubspec.yaml');
    if (!pubspecFile.existsSync()) return null;
    try {
      return pubspecFile.readAsStringSync();
    } on FileSystemException catch (e) {
      _logger.detail('Could not read pubspec.yaml: $e');
      return null;
    } on FormatException catch (e) {
      _logger.detail('Could not read pubspec.yaml: $e');
      return null;
    }
  }

  /// The resolved (version, source) pair: the trimmed `--version`
  /// flag wins when non-blank; otherwise the pubspec content (null
  /// content = no pubspec). The SOURCE is part of the contract — it
  /// names the file the operator must fix in any later validation
  /// error, and hand-assigning it in two run() branches let the two
  /// be swapped with every test green. Public for tests; reads its
  /// own args.
  (String?, String) resolvedVersionAndSource(String? pubspecContent) {
    final flagVersion = (argResults?['version'] as String?)?.trim();
    if (flagVersion != null && flagVersion.isNotEmpty) {
      return (flagVersion, '--version');
    }
    return (
      pubspecContent == null ? null : pubspecVersionFrom(pubspecContent),
      'pubspec.yaml',
    );
  }

  /// The rejection for a release version that can be neither stamped
  /// (Android yaml) nor matched by any device, or null. Uses the
  /// SAME predicate the Android stamp enforces with its uncaught
  /// ArgumentError ([isStampableReleaseVersion]), so the pre-check
  /// cannot silently diverge from the crash it exists to prevent.
  /// [source] names the producer so the operator checks the right
  /// place. Public for tests.
  String? versionValidationError(String version, {required String source}) {
    if (isStampableReleaseVersion(version)) return null;
    return 'Invalid release version "$version" (from $source): only '
        'letters, digits, ".", "_", "+", and "-" are allowed.';
  }

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

    // Blank boundary reads reject before anything is resolved.
    final blankError = blankArgError();
    if (blankError != null) {
      _logger.err(blankError);
      return ExitCode.usage.code;
    }

    // Shared --platform rule with the patch command: every platform
    // gate below is an exact-string compare that fails OPEN — a
    // wrong-cased value would skip the iOS baseline-identity
    // requirement and the Android packaged-lib rule silently. A
    // value the command does not understand must be a fast exit.
    final (platformArg, platformError) = platformArgOrError();
    if (platformError != null) {
      _logger.err(platformError);
      return ExitCode.usage.code;
    }

    // --snapshot names pre-existing bytes. Without --build nothing
    // will create a missing file, so a typo is an exit 64 HERE,
    // never a late failure after resolution work; with --build the
    // possibly-mistyped path draws a pre-build warning instead (at
    // the build block's emission point), because the build may be
    // about to create it.
    final willBuild = argResults?['build'] as bool? ?? false;
    final snapshotError = snapshotArgError(willBuild: willBuild);
    if (snapshotError != null) {
      _logger.err(snapshotError);
      return ExitCode.usage.code;
    }

    // Resolve app ID. Trimmed at the boundary: padding would be
    // invisible in the progress prose, encode as '+' on the wire,
    // and either fail AFTER the whole baseline upload or land the
    // release under an app id nothing polls.
    var appId = (argResults?['app-id'] as String?)?.trim();
    appId ??= await CodePushClient.getAppId();
    if (appId == null || appId.isEmpty) {
      _logger.err(
        'No app ID specified. Use --app-id, or run '
        '"fcp codepush init --app-id <id>" in this project to record an '
        'EXISTING app id (a bare "fcp codepush init" creates a NEW app) '
        '— the app id is resolved per project now, so a machine-wide '
        '"fcp config set codepush_app_id" is only a fallback for '
        'projects that set none.',
      );
      return ExitCode.usage.code;
    }

    // Resolve version — flag, then pubspec — via the tested helpers,
    // so the producer named in any later error is pinned rather
    // than assigned by hand in two branches.
    final (resolvedVersion, versionSource) =
        resolvedVersionAndSource(pubspecContentForVersion());
    final version = resolvedVersion;
    if (version == null || version.isEmpty) {
      // Worded for BOTH causes: no version anywhere, and a pubspec
      // that exists but could not be read (cause at --verbose).
      _logger.err(
        'No version specified. Use --version, or check that '
        'pubspec.yaml exists, is readable, and has a version: line.',
      );
      return ExitCode.usage.code;
    }
    if (versionSource == 'pubspec.yaml') {
      _logger.detail('Using version from pubspec.yaml: $version');
    }
    // One validation after both producers converge — exit 64 here,
    // not a mid-build crash or a silently unmatched server version.
    final versionError = versionValidationError(
      version,
      source: versionSource,
    );
    if (versionError != null) {
      _logger.err(versionError);
      return ExitCode.usage.code;
    }

    // If --build is set, build the app first.
    final shouldBuild = willBuild;
    final buildService =
        _injectedBuildService ?? CodePushBuildService(logger: _logger);
    String? baselineId;
    String? originalIosInfoPlist;
    // Why the iOS stamp produced no identity — carried to the terminal
    // identity error so its advice matches the ACTUAL cause (round-5
    // M1: "missing → flutter create ." is wrong and destructive for a
    // present-but-unusable plist).
    String? iosStampFailureCause;
    var iosPlistWasMissing = false;
    // Set when the stamp SUCCEEDED but the built app did not embed it
    // (a flavored INFOPLIST_FILE) and nothing else supplied an id — a
    // distinct no-identity cause from a failed/missing stamp.
    var iosStampNotConsumed = false;
    String? originalAndroidYaml;
    String? builtPlatform;

    if (shouldBuild) {
      var platform = platformArg;
      platform ??= buildService.detectPlatform();
      if (platform == null) {
        _logger.err(
          'Cannot detect platform. Use --platform to specify (apk, appbundle, ios, linux, macos, windows).',
        );
        return ExitCode.usage.code;
      }
      builtPlatform = platform;
      // Second emission point: the platform is only known here, and
      // the iOS-only axis needs it.
      final iosOnlyWarning =
          buildOnlyFlagsWarning(resolvedPlatform: builtPlatform);
      if (iosOnlyWarning != null) {
        _logger.warn(iosOnlyWarning);
      }
      // Third and fourth emission points (the iOS-only axis above is
      // the second): a probably-mistyped --snapshot, and the
      // foreign---snapshot record skips — both decided already, both
      // worth saying before minutes of build. The warning is
      // deliberately NOT platform-gated (a missing file is a
      // platform-neutral fact) while the advisory is iOS-only (the
      // records it names are iOS records).
      final missingSnapshotWarning = snapshotPreBuildWarning();
      if (missingSnapshotWarning != null) {
        _logger.warn(missingSnapshotWarning);
      }
      if (platform == 'ios') {
        final advisory = foreignSnapshotAdvisory();
        if (advisory != null) {
          _logger.warn(advisory);
        }
      }

      // Cheapest thing that can end this run: ask whether the saved
      // login still works, while nothing has been built. A dead token
      // used to surface only at the baseline UPLOAD — after the whole
      // build — so logging in cost a second build. Own client, closed
      // immediately: the upload path builds its own later, and a probe
      // must not extend anything's lifetime.
      final sessionClient = CodePushClient(
        serverUrl: await CodePushClient.getServerUrl(),
      );
      final int? sessionExit;
      try {
        sessionExit = await refuseOnExpiredSession(
          client: sessionClient,
          token: token,
          logger: _logger,
        );
      } finally {
        // force: `checkSession`'s 10s timeout abandons the future but
        // not the socket. Same rule the patch command writes down at
        // its own close site — a probe must leave nothing behind.
        sessionClient.close(force: true);
      }
      if (sessionExit != null) return sessionExit;

      final artifactManager = CodePushArtifactManager(logger: _logger);

      final flutterVersion = await buildService.resolveFlutterVersion(
        explicit: (argResults?['flutter-version'] as String?)?.trim(),
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

      final dartDefines = dartDefineValues();
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
          try {
            originalIosInfoPlist = writeBaselineIdToIosInfoPlist(
              generatedBaselineId,
            );
          } on FileSystemException catch (e) {
            // Same guard as the restore in the finally below: a
            // permissions problem (e.g. a read-only ios/Runner/)
            // must read as "unstamped build", not as a tool crash —
            // and not as "not found" (the file exists, unwritable).
            // The unstamped outcome is fully supported downstream.
            // The raw exception stays OUT of the cause: the exit
            // message splices the cause mid-sentence, and the warn
            // right below already prints the full exception once.
            // EMPIRICAL (pinned in ios_baseline_plist_read_test):
            // dart:io's readAsStringSync reports a non-UTF-8 file as
            // a FileSystemException whose message names the decode
            // ("Failed to decode data using encoding 'utf-8'"), NOT
            // as a FormatException — so the binary-plist family
            // arrives HERE and is split off, or every binary plist
            // would be misdiagnosed as permissions. The discriminator
            // is STRUCTURAL (no OSError + the decode message), not
            // lexical: renameSync interpolates the DESTINATION PATH
            // into its message, so a checkout under a decode*/
            // encoding*-named directory would fool a message-only
            // test; OS-level failures always carry an OSError, the
            // decode exception never does.
            iosStampFailureCause = iosStampCauseFor(e);
            // The source plist is untouched by a failed stamp, so a
            // plist that already carries an id STILL ships it — don't
            // assert "will not embed" when it might.
            final alreadyStamped = readBaselineIdFromSourceInfoPlist() != null;
            _logger.warn(
              'Could not stamp ios/Runner/Info.plist: $e. '
              '${alreadyStamped ? 'The id already committed to the plist will still ship; this build could not add or refresh one.' : 'This build will not embed a baseline identity.'}',
            );
            originalIosInfoPlist = null;
          } on FormatException catch (e) {
            // Defensive belt: today's SDK reports non-UTF-8 as the
            // FileSystemException above; keep this in case a future
            // SDK surfaces the decode error directly. Route the cause
            // and the already-shipped check the SAME way so the belt
            // can't re-introduce the over-assertion the sibling fixed
            // (a binary plist is exactly where a pre-committed id is
            // most likely present).
            iosStampFailureCause = 'ios/Runner/Info.plist is not '
                'readable as UTF-8 text (a binary plist?)';
            final alreadyStamped = readBaselineIdFromSourceInfoPlist() != null;
            _logger.warn(
              'Could not read ios/Runner/Info.plist as UTF-8 text '
              '(a binary plist?): $e. '
              '${alreadyStamped ? 'The id already committed to the plist will still ship; this build could not add or refresh one.' : 'This build will not embed a baseline identity.'}',
            );
            originalIosInfoPlist = null;
          }
          if (originalIosInfoPlist == null && iosStampFailureCause == null) {
            // Null without a throw has THREE causes; "not found" for a
            // file the operator can see would send them hunting, and a
            // dangling symlink (existsSync follows links → false) is
            // neither missing nor malformed and "flutter create ."
            // won't fix it.
            // A DEAD link only: a symlink (followLinks:false → link)
            // whose target is absent (followLinks:true → notFound).
            // A live link to a present-but-malformed target falls
            // through to the malformed branch, which is the true cause.
            final isDeadLink = FileSystemEntity.typeSync(
                      kDefaultIosInfoPlistPath,
                      followLinks: false,
                    ) ==
                    FileSystemEntityType.link &&
                FileSystemEntity.typeSync(
                      kDefaultIosInfoPlistPath,
                    ) ==
                    FileSystemEntityType.notFound;
            iosPlistWasMissing =
                !isDeadLink && !File(kDefaultIosInfoPlistPath).existsSync();
            iosStampFailureCause = isDeadLink
                ? 'ios/Runner/Info.plist is a symbolic link whose '
                    'target does not exist — restore the target'
                : iosPlistWasMissing
                    ? 'ios/Runner/Info.plist is missing'
                    : 'ios/Runner/Info.plist has no closing </dict> — '
                        'truncated, or not an XML plist';
            _logger.warn(
              'Warning: $iosStampFailureCause. '
              'This build will not embed a baseline identity.',
            );
          } else if (originalIosInfoPlist != null) {
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
          var androidStampFailed = false;
          try {
            originalAndroidYaml = writeReleaseVersionToAndroidYaml(version);
            androidStampFailed = false;
          } on FileSystemException catch (e) {
            // Mirror of the iOS stamp guard above — including the
            // structural decode split (no OSError + the decode
            // message; see the iOS twin for the renameSync
            // path-contamination trap a message-only test has).
            final isDecodeFailure =
                e.osError == null && e.message.contains('Failed to decode');
            _logger.warn(
              isDecodeFailure
                  ? 'Could not read $kDefaultAndroidCodePushYamlPath '
                      'as UTF-8 text: $e. '
                      'This build will not embed a release version.'
                  : 'Could not stamp $kDefaultAndroidCodePushYamlPath: '
                      '$e. '
                      'This build will not embed a release version.',
            );
            originalAndroidYaml = null;
            androidStampFailed = true;
          } on FormatException catch (e) {
            // Defensive belt — see the iOS twin.
            _logger.warn(
              'Could not read $kDefaultAndroidCodePushYamlPath as '
              'UTF-8 text: $e. '
              'This build will not embed a release version.',
            );
            originalAndroidYaml = null;
            androidStampFailed = true;
          }
          if (originalAndroidYaml == null && !androidStampFailed) {
            // A dangling symlink reads as absent (existsSync follows
            // links) but "run fcp codepush init" is the wrong advice —
            // the target is missing, not the config (the iOS twin got
            // this split in round 14). Non-destructive either way, so
            // Low, but the accurate cause saves a hunt.
            final isDeadLink = FileSystemEntity.typeSync(
                      kDefaultAndroidCodePushYamlPath,
                      followLinks: false,
                    ) ==
                    FileSystemEntityType.link &&
                FileSystemEntity.typeSync(kDefaultAndroidCodePushYamlPath) ==
                    FileSystemEntityType.notFound;
            _logger.warn(
              isDeadLink
                  ? '$kDefaultAndroidCodePushYamlPath is a symbolic link '
                      'whose target does not exist — restore the target. '
                      'This build will not embed a release version.'
                  : 'Warning: $kDefaultAndroidCodePushYamlPath not found. '
                      'This build will not embed a release version. '
                      'Run "fcp codepush init" to set up Android.',
            );
          } else if (originalAndroidYaml != null) {
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
          if (argResults?['interface-freeze'] as bool? ?? true) {
            final freezeArgs = await prepareIosInterfaceFreeze(buildService);
            if (freezeArgs == null) return ExitCode.software.code;
            releaseBuildArgs = freezeArgs(releaseBuildArgs);
          } else {
            _logger.warn(kInterfaceFreezeDisabledWarning);
          }
        }

        final buildProgress = _logger.progress('Building release ($platform)');
        final buildOk = await buildService.buildRelease(
          platform: platform,
          extraArgs: releaseBuildArgs,
          artifactManager: artifactManager,
          flutterVersion: flutterVersion,
        );
        if (!buildOk) {
          failReleaseStep(buildProgress, 'Build failed');
          return ExitCode.software.code;
        }
        buildProgress.complete('Build succeeded');
        checkInterfaceReportAfterBuild();

        final finalizeProgress = _logger.progress('Finalizing build');
        final finalized = await buildService.finalizeBuild(
          buildPlatform: platform,
          flutterVersion: flutterVersion,
          artifactManager: artifactManager,
        );
        if (finalized.success) {
          finalizeProgress.complete('Build finalized');
        } else {
          failReleaseStep(
            finalizeProgress,
            finalized.message ?? 'Finalization failed',
            diagnostics: finalized.formatDiagnostics(),
          );
          return ExitCode.software.code;
        }
      } finally {
        if (originalIosInfoPlist != null) {
          try {
            restoreIosInfoPlist(originalIosInfoPlist);
            _logger.detail('Restored ios/Runner/Info.plist');
          } on FileSystemException catch (e) {
            // Mirror of the Android restore below: a throw escaping a
            // finally would REPLACE any in-flight build error with an
            // unhandled FileSystemException the runner does not catch,
            // and leave the stamped plist in the tree with no guidance.
            _logger.err(
              'Failed to restore ios/Runner/Info.plist after the '
              'build: $e\n'
              '${restoreFailureGuidance(spelled: kDefaultIosInfoPlistPath, stampedValueDescription: 'the stamped FCPBaselineId')}',
            );
          }
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
              'build: $e\n'
              '${restoreFailureGuidance(spelled: kDefaultAndroidCodePushYamlPath, stampedValueDescription: 'the stamped release version')}',
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
    final explicitPlatform = platformArg;
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

    // The no-build advisory emits HERE, where the platform is known:
    // the identity flags are iOS-only reads, and the round-46 split
    // made 'iOS' the load-bearing word — a no-build apk release with
    // --baseline-id was read by nothing and said nothing. (The build
    // path's emission point is inside the build block.)
    if (!shouldBuild) {
      final releaseBuildOnlyWarning =
          buildOnlyFlagsWarning(resolvedPlatform: resolvedPlatform);
      if (releaseBuildOnlyWarning != null) {
        _logger.warn(releaseBuildOnlyWarning);
      }
    }

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
      // The core's directory text says "--snapshot names…"; for a
      // detector-resolved path the operator never typed, keep the
      // plain form.
      final explicitSnapshot =
          ((argResults?['snapshot'] as String?)?.trim().isNotEmpty ?? false);
      _logger.err(
        explicitSnapshot
            ? missingSnapshotCore(snapshotPath)
            : 'Snapshot file not found: $snapshotPath.',
      );
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
    // ONE read for the whole run (the getter re-resolves symlinks on
    // every access, and a workspace cleanup between the identity,
    // the attestation, and the archive gate could move later calls
    // to a different tier — the records must share one answer).
    final snapshotIsForeign = usedExplicitSnapshot;
    if (resolvedPlatform == 'ios') {
      final appDirForIdentity = builtIosAppDirFromBinaryPath(snapshotPath);
      // Captured BEFORE the reassignment: the third-state message
      // below asserts a stamp happened, which only this knows.
      final stampedByThisBuild = baselineId;
      // The stamp is withheld when --snapshot names foreign bytes:
      // the stamped UUID lives only in the locally-built app that
      // was never shipped, and recording it would create the
      // no-error-anywhere never-updates release this block's own
      // comment warns about — the foreign bundle's own id (or the
      // explicit flag) is the identity of what actually serves.
      // Fourth record on the usedExplicitSnapshot rule, beside the
      // attestation, the saved app, and the archive.
      // The null-cause detail matters HERE and nowhere else: this is
      // the read the stamp-consumed check escalates to exit 64, so a
      // false null (plutil failure, unreadable plist) must be
      // diagnosable from --verbose instead of reading as a tool bug.
      final idFromBuiltApp = appDirForIdentity != null
          ? readBaselineIdFromBuiltAppPlist(
              appPath: appDirForIdentity,
              onNullCause: (cause) => _logger.detail(
                'No FCPBaselineId read from the built app: $cause',
              ),
            )
          : null;
      baselineId = resolveIosBaselineId(
        stampedByBuild: snapshotIsForeign ? null : baselineId,
        explicitFlag: argResults?['baseline-id'] as String?,
        fromBuiltApp: idFromBuiltApp,
      );
      // "Stamp succeeded" only means writeBaselineIdToIosInfoPlist
      // wrote ios/Runner/Info.plist — NOT that xcodebuild packaged it.
      // A flavored target (INFOPLIST_FILE → ios/Runner/Info-Prod.plist)
      // ships a different plist, so the built app's OWN id — what
      // devices actually present — is authoritative over the stamp.
      final explicitBaselineIdFlag =
          (argResults?['baseline-id'] as String?)?.trim();
      if (shouldBuild &&
          !snapshotIsForeign &&
          stampedByThisBuild != null &&
          appDirForIdentity != null) {
        final warn = stampConsumedWarning(
          stampedByThisBuild: stampedByThisBuild,
          embeddedInBuiltApp: idFromBuiltApp,
        );
        if (warn != null) {
          _logger.warn(warn);
          // The embedded id is what ships; prefer it over the stamp
          // (null → the release honestly has no matchable identity).
          // Blank normalizes to absent, matching stampConsumedWarning's
          // own blank-trim row — '' must never become a recorded
          // baseline_id nor slip past the no-identity gate below.
          final embeddedTrimmed = idFromBuiltApp?.trim();
          baselineId = (embeddedTrimmed == null || embeddedTrimmed.isEmpty)
              ? null
              : embeddedTrimmed;
          // Flag the null case so the no-identity exit below tells the
          // truth: the stamp SUCCEEDED but the build didn't consume it,
          // which is a different cause than a failed/missing stamp
          // (and "flutter create ." would be wrong, destructive advice).
          iosStampNotConsumed = baselineId == null;
          // A passed flag must be accounted for on THIS row — at
          // default verbosity (round-19 Low) — but only when its fate
          // needs explaining: an AGREEING flag (the round-23 M1 case,
          // the flow the CHANGELOG itself prescribes for flavored
          // targets) is not superseded — the release is recorded
          // under the flag's own value — and reporting it as ignored
          // sends the operator hunting a disagreement that does not
          // exist. Pure and rowed in baselineIdFlagNotice.
          final flagNotice = baselineIdFlagNotice(
            recordedId: baselineId,
            explicitFlag: explicitBaselineIdFlag,
            allowMissingBaseline:
                argResults?['allow-missing-baseline'] as bool? ?? false,
          );
          if (flagNotice != null) {
            _logger.warn(flagNotice);
          }
        }
      }
      if (shouldBuild &&
          !snapshotIsForeign &&
          stampedByThisBuild != null &&
          !iosStampNotConsumed &&
          baselineId == stampedByThisBuild &&
          explicitBaselineIdFlag != null &&
          explicitBaselineIdFlag.isNotEmpty) {
        // The last flag read by nothing: correct (the built bytes
        // carry the stamp) but no longer silent. Suppressed when the
        // stamp was NOT what shipped — the embedded-id-differs row
        // emits its own superseded-by-the-bytes WARNING above, and
        // the nothing-embedded row is headed for the no-identity
        // exit, where the flag gets its own clause.
        _logger.detail(
          '--baseline-id is superseded by the id this build stamped; '
          'ignoring the flag.',
        );
      }
      // The flag's contract is "the id embedded in the app you are
      // releasing". On a --build run releasing THIS build's bytes,
      // that is checkable — and a flag the bytes contradict must not
      // become the release's identity: recording an id the shipped
      // app does not carry makes three records (server row, saved
      // bundle, archive) agree on a lie, and a device that DOES send
      // an embedded id can then never match the release (hard 204).
      // Reachable exactly when the stamp failed (e.g. the read-only
      // ios/Runner/ this feature's CHANGELOG documents) and the
      // operator followed the old "pass --baseline-id" advice.
      final contradiction = baselineIdContradiction(
        shouldBuild: shouldBuild,
        snapshotIsForeign: snapshotIsForeign,
        stampedByThisBuild: stampedByThisBuild,
        explicitFlag: explicitBaselineIdFlag,
        embeddedInBuiltApp: idFromBuiltApp,
        stampFailureCause: iosStampFailureCause,
      );
      if (contradiction != null) {
        if (argResults?['allow-missing-baseline'] as bool? ?? false) {
          // The opt-out drops the contradicting FLAG, not the truth:
          // when the built bytes carry an id, releasing under THAT id
          // is strictly better than identity-less (the refusal's own
          // remedy is "drop the flag to use the embedded id") — so
          // the fallback lands exactly where dropping the flag
          // would. Only the nothing-embedded variant proceeds
          // identity-less, the outcome the opt-out names.
          baselineId =
              baselineIdUnderOptOut(embeddedInBuiltApp: idFromBuiltApp);
          _logger.warn(
            baselineId != null
                ? '$contradiction Ignoring --baseline-id and releasing '
                    'under the id the built app embeds ($baselineId).'
                : '$contradiction Ignoring --baseline-id and proceeding '
                    'WITHOUT a baseline identity per '
                    '--allow-missing-baseline.',
          );
        } else {
          _logger.err(
            '$contradiction '
            '${idFromBuiltApp == null ? 'Fix the stamp (writable ios/Runner/), pre-stamp Info.plist with this exact id, or drop the flag and pass --allow-missing-baseline.' : 'Drop the flag to use the embedded id, or fix the plist to carry the intended one.'}',
          );
          return ExitCode.usage.code;
        }
      }
      if (baselineId != null) {
        _logger.detail('Using baseline id: $baselineId');
      } else if (!(argResults?['allow-missing-baseline'] as bool? ?? false)) {
        if (shouldBuild && snapshotIsForeign) {
          // Third state (a foreign --snapshot on a run that BUILT —
          // stamped or not: the stamp is withheld for foreign bytes
          // either way, so a failed stamp changes nothing about this
          // outcome, and routing it to the plist branch would tell
          // the user to fix the plist, burn a second build, and land
          // right back here; the pre-build advisory already named
          // the real cause. Without --build the sibling branch below
          // is correct and --allow-missing-baseline is the
          // legitimate escape):
          // the snapshot carries no readable id, and any id this run
          // stamped belongs to an app that never shipped.
          // --allow-missing-baseline is deliberately not suggested —
          // it produces the never-updated release warned about above.
          _logger.err(
            'No baseline identity: --snapshot names bytes other than '
            "this run's build output, so "
            '${stampedByThisBuild != null ? "the build's stamped id does not apply" : "a stamped id would not apply even if the build had produced one (this build's stamp also failed: ${iosStampFailureCause ?? 'see the warning above'})"}'
            ', and the snapshot carries no readable '
            'FCPBaselineId. Pass --baseline-id <the id embedded in the '
            "app those bytes come from>, point --snapshot at this "
            "build's own binary, or drop --snapshot.",
          );
        } else if (iosStampNotConsumed) {
          // The stamp SUCCEEDED but the built app didn't embed it (the
          // M1 warning above said why: a flavored INFOPLIST_FILE). NOT
          // a stamp failure — "flutter create ." would be wrong and
          // destructive, and the plist is present. Point at the real
          // fix: make the target consume ios/Runner/Info.plist, or
          // stamp the plist the target actually uses.
          _logger.err(
            'No baseline identity: this build stamped '
            'ios/Runner/Info.plist but the shipped app embeds no '
            'FCPBaselineId, so no device would match a release recorded '
            'under it. '
            // The flag the operator DID pass must not look silently
            // ignored: it fails for the same reason the stamp does.
            '${explicitBaselineIdFlag != null && explicitBaselineIdFlag.isNotEmpty ? '--baseline-id cannot substitute: the shipped bytes embed no id, so no device would send it. ' : ''}'
            'Point your iOS target at ios/Runner/Info.plist '
            '(or commit an FCPBaselineId into the plist your target '
            'actually uses), or pass --allow-missing-baseline to accept '
            'a release matched by fallback rather than by identity.',
          );
        } else if (shouldBuild) {
          // The build ran but could not stamp; the branch above
          // recorded WHY. Telling the user to "re-run with --build"
          // would send them in a circle, and "flutter create ."
          // advice is destructive for a present-but-unusable plist —
          // it is offered only when the plist is genuinely absent.
          // --baseline-id is deliberately NOT suggested here: this
          // branch means the built bytes embed nothing (a pre-stamped
          // plist would have resolved via fromBuiltApp and never
          // reached it), so the flag would name an id the app does
          // not carry — the exact release the guard above refuses.
          _logger.err(
            'The build could not stamp a baseline identity: '
            '${iosStampFailureCause ?? 'ios/Runner/Info.plist is missing'}. '
            '${iosPlistWasMissing || iosStampFailureCause == null ? 'Restore the plist ("flutter create ." regenerates it) and re-run, or pass ' : 'Fix that and re-run, or pass '}'
            '--allow-missing-baseline if you accept a release matched '
            'by fallback rather than by identity.',
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
    // Trimmed at the boundary: the server records this verbatim as
    // the SDK every future patch compiles against, and the padded
    // shape otherwise becomes an engine-cache path with a space.
    var flutterVersion = (argResults?['flutter-version'] as String?)?.trim();
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

    final attestation = interfaceAttestation(
      shouldBuild: shouldBuild,
      builtPlatform: builtPlatform,
      usedExplicitSnapshot: snapshotIsForeign,
    );
    try {
      final result = await client.createRelease(
        token: token,
        appId: appId,
        version: version,
        snapshotData: snapshotData,
        flutterVersion: flutterVersion,
        baselineId: baselineId,
        interfaceFreeze: attestation.interfaceFreeze,
        extendableWidgets: attestation.extendableWidgets,
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

      // The 201 already happened: from here on a shape surprise must
      // degrade to the unarchived-but-released path, never throw into
      // the outer catch (exit 70 reads as failure and invites the CI
      // retry that duplicates the release).
      final release = CodePushClient.asJsonMap(result['release']);
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

      // Save the iOS baseline app for later device install — gated
      // like the archive below: with an explicit --snapshot the
      // saved bundle is NOT what this release serves (the recorded
      // snapshot_hash is the foreign bytes'), and a device installed
      // from it would silently fail the baseline check on every
      // patch.
      // Not gated on baselineId: the --allow-missing-baseline corner
      // has a null id and skips all three records too — silence
      // there was the worst combination.
      if (builtPlatform == 'ios' && snapshotIsForeign) {
        // The skip must not be silent: pre-gate this invocation
        // printed the loud saved-app SUCCESS block, so its visible
        // replacement must also be visible at default verbosity.
        _logger.info(
          'Skipping the saved baseline app and per-release archive, and '
          'recording the interface attestation as unknown (the patch-time '
          'guard will not fire for this release): --snapshot named bytes '
          'other than this build\'s output, so the built bundle is not '
          'what this release serves.',
        );
      }
      if (builtPlatform == 'ios' && !snapshotIsForeign && baselineId == null) {
        // Mirror corner (--allow-missing-baseline with a failed
        // stamp): the records are skipped for a different cause, and
        // that skip must be as visible as the foreign-snapshot one.
        // "applies to the shipped bytes", not "was stamped": the
        // not-consumed path DID stamp — the build just didn't ship it
        // — and this message must not contradict that warning.
        _logger.info(
          'Skipping the saved baseline app and per-release archive: no '
          'baseline identity applies to the shipped bytes (see the '
          'warning above), so a saved bundle could not be replayed '
          'against this release.',
        );
      }
      if (builtPlatform == 'ios' && baselineId != null && !snapshotIsForeign) {
        // The archive is gated on the SAVE having succeeded: a failed
        // delete leaves the PREVIOUS release's bundle at the saved
        // path, and archiving it under this release's id would break
        // the two-records-one-story invariant the best-effort
        // conversion must not trade away.
        final saved = saveIosBaselineApp(baselineId: baselineId);

        // Archive the saved baseline app + dSYM into a per-release
        // directory so a future device replay can reinstall the exact
        // bundle that produced this release. Best-effort; never fails
        // a successful release. Mirrors interfaceAttestation's
        // --snapshot un-attestation: when an explicit --snapshot
        // overrode the built bytes, the archived bundle would NOT be
        // what this release serves, and a manifest claiming its spec
        // attestation would out-claim the server record — so no
        // archive is written for that release at all (the two records
        // must tell the same story).
        // Tolerant read (the releaseFromListing rule): a non-String
        // id must not throw a TypeError AFTER the release was
        // created — CI would retry and duplicate the release.
        final releaseId = release?['id']?.toString().trim();
        if (saved && releaseId != null && releaseId.isNotEmpty) {
          archiveIosBaseline(releaseId: releaseId, baselineId: baselineId);
        } else {
          // The block's rule: no silent skips. Covers every inner
          // save failure (the false) and the no-release-id corner.
          _logger.info(
            'Skipping the per-release archive: '
            '${saved ? 'the server returned no release id' : 'the baseline app was not saved this run (no built Runner.app, or the copy or swap failed — see any warning above)'}'
            ' — archiving would record a bundle that did not produce '
            'this release.',
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
  /// (with an error logged) when the freeze cannot be set up, or
  /// throws [FlutterCompileException] when the spec directory or spec
  /// file cannot be written (the message is logged here first; the
  /// runner exits without a second print).
  /// Building without it would ship a baseline that later patches
  /// cannot call reliably, so that is a hard failure, not a warning.
  ///
  /// The spec lists only libraries the compile actually contains
  /// (discovered via a fast front-end pre-pass), because a listed
  /// library that is absent from the compile fails the whole build.
  /// Public for tests (no meta dependency for @visibleForTesting);
  /// production callers stay inside this command.
  Future<List<String> Function(List<String>)?> prepareIosInterfaceFreeze(
    CodePushBuildService buildService, {
    String? projectRootOverride,
  }) async {
    writtenInterfaceSpec = null;
    interfaceReportObservedAfterBuild = false;
    final projectRoot = projectRootOverride ?? Directory.current.path;
    final pubspec = File('$projectRoot/pubspec.yaml');
    String? packageName;
    try {
      packageName = pubspec.existsSync()
          ? CodePushBuildService.parsePubspecName(pubspec.readAsStringSync())
          : null;
    } on FileSystemException {
      // A present-but-unreadable pubspec (mode bits, sudo-created file)
      // gets the same actionable error as a missing/nameless one, not a
      // raw exception.
      packageName = null;
    }
    if (packageName == null) {
      _logger.err(
        'Could not read the package name from pubspec.yaml (check that '
        'the file exists and is readable); cannot prepare the iOS '
        'release build.',
      );
      return null;
    }
    final specDir = Directory('$projectRoot/build/codepush');
    final reportPath =
        '${specDir.path}/${CodePushBuildService.kInterfaceReportFilename}';
    // Fail fast on a comma in the project path (reportPath embeds it),
    // before any side effects and before the expensive pre-pass. The
    // authoritative check on the service-composed spec path still runs
    // after the write.
    if (reportPath.contains(',')) {
      _logger.err(
        'The project path contains a comma, which the build toolchain '
        'cannot pass through. Move the project to a comma-free path.',
      );
      return null;
    }
    try {
      specDir.createSync(recursive: true);
    } on FileSystemException catch (e) {
      // On a fresh checkout this directory does not exist yet, so a
      // read-only workspace or full disk fails HERE, not at the guarded
      // spec write below — same failure class, same guidance.
      final reason = e.osError?.message ?? e.message;
      final message =
          'Could not create ${specDir.path} ($reason). Check permissions '
          'and free space on the build directory.';
      _logger.err(message);
      throw FlutterCompileException(message);
    }
    // fcp never writes the report itself — the front end does, later in
    // the build. Delete a previous run's copy now, so a build that
    // emits none surfaces as the missing-artifact breadcrumb instead of
    // archiving stale evidence under this run's attestation.
    try {
      File(reportPath).deleteSync();
    } on PathNotFoundException {
      // Absent — the common case.
    } on FileSystemException catch (e) {
      // A surviving leftover would defeat the stale-evidence guarantee;
      // an unwritable directory hard-stops at the spec write below, so
      // a breadcrumb suffices here.
      _logger.detail('Could not delete a previous interface report: $e');
    }
    final flutterRoot = buildService.findFlutterRootForProbe();
    if (flutterRoot == null ||
        !buildService.frontendSupportsFreeze(flutterRoot)) {
      _logger.err(
        'This Flutter SDK\'s compiler does not support preserving call '
        'shapes for code push. Upgrade Flutter (3.41+), or pass '
        '--no-interface-freeze to build without it (such a release may '
        'not be reliably patchable).',
      );
      // The report was already deleted above; the previous run's spec
      // must go with it — the two must never describe different runs.
      freeze_files.sweepInterfaceSpecs(specDir.path);
      return null;
    }
    final allowExtendable = argResults?['extendable-widgets'] as bool? ?? true;
    if (!allowExtendable) {
      _logger.warn(
        'Extendable widget guarding disabled (--no-extendable-widgets): '
        'patches that add new widget subclasses will fail on this release.',
      );
    }
    final progress = _logger.progress('Analyzing app libraries');
    final closure = await buildService.discoverCompileClosure(
      targetPath: 'lib/main.dart',
      workDirPath: specDir.path,
      projectRootOverride: projectRootOverride,
    );
    if (closure == null) {
      progress.fail('Could not analyze the app for the release build');
      // Same pairing rule as the probe refusal above.
      freeze_files.sweepInterfaceSpecs(specDir.path);
      return null;
    }
    final ({
      String specPath,
      int appCount,
      int flutterCount,
      bool extendable,
      freeze_files.InterfaceSpecChange specChange
    })? writtenSpec;
    try {
      writtenSpec = buildService.writeIosInterfaceFreezeSpec(
        closurePaths: closure,
        projectRoot: projectRoot,
        packageName: packageName,
        specDirPath: specDir.path,
        allowExtendable: allowExtendable,
        onSkip: (path, reason) => _logger.warn('Not frozen ($reason): $path'),
      );
    } on FlutterCompileException catch (e) {
      progress.fail('Could not write the interface spec');
      _logger.err(e.message);
      rethrow;
    }
    // The compile target lib/main.dart is always in its own closure, so
    // a null here means the path-prefix match failed, not that the app
    // has no libraries. Shipping without the app's own shapes frozen
    // silently defeats the feature - hard stop.
    if (writtenSpec == null) {
      progress.fail('Could not map the app libraries for the release');
      _logger.err(
        'No app libraries were mapped into the interface freeze; '
        'building anyway would ship an app whose own code cannot be '
        'reliably patched. Please report this with your project layout.',
      );
      return null;
    }
    // Defence-in-depth: the directory portion was already refused up
    // front and the hashed filename is comma-free by construction, so
    // this fires only if either composition ever changes shape. The
    // surrounding tooling re-splits the option list on commas, so a
    // comma here would silently corrupt every option after it.
    if (writtenSpec.specPath.contains(',') || reportPath.contains(',')) {
      progress.fail('Could not use the interface spec path');
      _logger.err(
        'The project path contains a comma, which the build toolchain '
        'cannot pass through. Move the project to a comma-free path.',
      );
      // No artifact may suggest a refused build used it.
      try {
        File(writtenSpec.specPath).deleteSync();
      } on FileSystemException {
        // Best effort; the next successful run overwrites it.
      }
      return null;
    }
    // A real Flutter app's compile always contains the framework
    // library, so a gate miss here is an anomaly, not a configuration —
    // and shipping without widget guarding silently defeats the feature
    // the same way an unmapped app would (hard stop above). The opt-out
    // flag is the documented acknowledgement.
    if (allowExtendable && !writtenSpec.extendable) {
      progress.fail('Widget base classes could not be marked extendable');
      _logger.err(
        'The Flutter framework library '
        '(${CodePushBuildService.kIosExtendableFrameworkLibrary}) was not '
        'found in the compile, so patches that add new widget subclasses '
        'would fail on this release. Likeliest causes: your Flutter SDK '
        'is newer than this fcp version supports, or the app genuinely '
        'never uses widgets. Build with --no-extendable-widgets to '
        'acknowledge shipping without widget guarding, or report this '
        'with your fcp and Flutter versions.',
      );
      // The spec was already written above; the build it described was
      // just refused, so no artifact should suggest this run used it.
      try {
        File(writtenSpec.specPath).deleteSync();
      } on FileSystemException {
        // Best effort; the next successful run overwrites it.
      }
      return null;
    }
    progress.complete(
      'Interface: ${writtenSpec.appCount} app + '
      '${writtenSpec.flutterCount} framework libraries'
      '${writtenSpec.extendable ? '' : ' (widget guarding off)'}',
    );
    // Captured variables do not promote; bind the non-null value.
    final String frozenSpecPath = writtenSpec.specPath;
    writtenInterfaceSpec = (
      path: frozenSpecPath,
      reportPath: reportPath,
      extendable: writtenSpec.extendable,
      specChange: writtenSpec.specChange,
    );
    return (args) => CodePushBuildService.withIosReleaseFrontEndOptions(
          args,
          freezeSpecPath: frozenSpecPath,
          reportPath: reportPath,
        );
  }

  /// Fail a release build/finalize progress line, print any step
  /// diagnostics, then surface the freeze escape hatch when this run
  /// applied the freeze — both failure paths share this one tested
  /// wire. Public for tests ([run] itself cannot be cheaply
  /// exercised).
  void failReleaseStep(
    Progress progress,
    String message, {
    String diagnostics = '',
  }) {
    progress.fail(message);
    if (diagnostics.isNotEmpty) {
      _logger.err(diagnostics);
    }
    final freezeHint = buildFailureFreezeHint();
    if (freezeHint != null) {
      _logger.err(freezeHint);
    }
  }

  /// The escape-hatch hint for a failed release build that included
  /// the interface freeze, or null when no freeze was applied. Every
  /// other failure on this path names its flag; a build broken by the
  /// freeze's new compiler inputs must too. Public for tests ([run]
  /// itself cannot be cheaply exercised).
  String? buildFailureFreezeHint() {
    final spec = writtenInterfaceSpec;
    if (spec == null) return null;
    final flags = spec.extendable
        ? '--no-extendable-widgets, or --no-interface-freeze'
        : '--no-interface-freeze';
    return 'This build included the code push interface freeze. If the '
        'failure above mentions the dynamic interface, retry with '
        '$flags (a release built without it may not be reliably '
        'patchable).';
  }

  /// The interface attestation for THIS run's upload. Nulls (unknown)
  /// unless the uploaded bytes came from an iOS build this run
  /// performed — and an explicit `--snapshot` OVERRIDES the built
  /// artifact, so it un-attests: recording `true` for foreign bytes
  /// would silence the patch-time warning on a release that most
  /// needs it. Nulls again when the evidence contradicts the intent:
  /// the freeze is proven by the compiler's report, or by a cache hit
  /// on an IDENTICAL spec (unchanged — the content-addressed name
  /// guarantees a reused compile saw these exact bytes). A missing
  /// report on any OTHER spec state is unexplainable — `changed` is
  /// the suspected-SDK-drift state, and `unknown` includes the
  /// from-scratch clean-CI build, where no cache hit can excuse the
  /// absence ([checkInterfaceReportAfterBuild] warns on exactly this
  /// split) — so the server record must tell the same story as the
  /// archive. With the freeze deliberately off, intent and fact
  /// agree: false.
  /// Public for tests ([run] cannot be cheaply exercised).
  ({bool? interfaceFreeze, bool? extendableWidgets}) interfaceAttestation({
    required bool shouldBuild,
    required String? builtPlatform,
    required bool usedExplicitSnapshot,
  }) {
    if (!shouldBuild || builtPlatform != 'ios' || usedExplicitSnapshot) {
      return (interfaceFreeze: null, extendableWidgets: null);
    }
    final spec = writtenInterfaceSpec;
    if (spec == null) {
      return (interfaceFreeze: false, extendableWidgets: false);
    }
    if (!interfaceReportObservedAfterBuild &&
        spec.specChange != freeze_files.InterfaceSpecChange.unchanged) {
      return (interfaceFreeze: null, extendableWidgets: null);
    }
    return (interfaceFreeze: true, extendableWidgets: spec.extendable);
  }

  /// Archive the saved baseline for [releaseId], attesting the spec
  /// THIS run wrote (see [writtenInterfaceSpec]). Public for tests: the
  /// wire from the field to the archive service is the one link
  /// [run] cannot cheaply exercise (it needs a token, a server, and a
  /// real build).
  void archiveIosBaseline({
    required String releaseId,
    required String baselineId,
  }) {
    // One read of the field, so every attested fact below describes the
    // same record — and the path/verdict pair travels as one value.
    final spec = writtenInterfaceSpec;
    (_injectedArchiveService ?? CodePushArchiveService(logger: _logger))
        .archiveIosRelease(
      releaseId: releaseId,
      baselineId: baselineId,
      fcpVersion: packageVersion,
      interfaceSpec:
          spec == null ? null : (path: spec.path, change: spec.specChange),
      interfaceReportPath: spec?.reportPath,
      interfaceReportWasProduced: interfaceReportObservedAfterBuild,
      interfaceSpecExtendable: spec?.extendable ?? false,
    );
  }

  /// Best-effort BY CONSTRUCTION (the archive sibling's shape): a
  /// post-success step must never fail a created release, so the
  /// whole body is inside the try — deleting a caller-side wrapper
  /// can no longer restore the exit-70 path. Public for tests;
  /// [projectRootOverride] anchors the const paths.
  bool saveIosBaselineApp({
    required String baselineId,
    String? projectRootOverride,
  }) {
    final root = projectRootOverride == null ? '' : '$projectRootOverride/';
    final source = '$root$kDefaultBuiltIosAppPath';
    final dest = '${root}build/codepush/baseline/Runner.app';
    try {
      return _saveIosBaselineAppUnguarded(
        baselineId: baselineId,
        source: source,
        dest: dest,
      );
    } catch (e) {
      _logger.warn('Saved-baseline step skipped: $e');
      return false;
    }
  }

  bool _saveIosBaselineAppUnguarded({
    required String baselineId,
    required String source,
    required String dest,
  }) {
    final sourceDir = Directory(source);
    if (!sourceDir.existsSync()) {
      _logger.detail('No built Runner.app to save.');
      return false;
    }

    // Copy to a sibling temp destination FIRST, then swap: deleting
    // the previous bundle before the copy is known to land would
    // trade good replayable state for nothing on a full disk (the
    // realistic failure — this runs right after the build filled
    // build/). The 2x peak footprint while both copies coexist is
    // the accepted price. A kill mid-copy can leave a full-size
    // <dest>.tmp behind; it lives under build/ (ships nowhere) and
    // the delete below clears it on the next run.
    final destDir = Directory(dest);
    final tmpDest = Directory('$dest.tmp');
    if (tmpDest.existsSync()) {
      tmpDest.deleteSync(recursive: true);
    } else {
      // A plain file or dangling symlink at the temp path (some
      // earlier mishap) is invisible to Directory.existsSync and
      // would otherwise make cp fail on EVERY subsequent run.
      final occupant =
          FileSystemEntity.typeSync(tmpDest.path, followLinks: false);
      if (occupant == FileSystemEntityType.link) {
        Link(tmpDest.path).deleteSync();
      } else if (occupant != FileSystemEntityType.notFound) {
        File(tmpDest.path).deleteSync();
      }
    }
    destDir.parent.createSync(recursive: true);
    final result = Process.runSync('cp', ['-R', source, tmpDest.path]);
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      // A partial copy is the classic ENOSPC/permissions shape, and
      // the same problem that failed the cp plausibly fails the
      // delete — so clean up FIRST and report what actually happened,
      // never claiming a discard that a hundreds-of-MB partial .tmp
      // is still sitting on disk contradicting (the swap-failure
      // branch below does the same).
      var tmpState = 'Any partial copy was discarded';
      try {
        if (tmpDest.existsSync()) {
          tmpDest.deleteSync(recursive: true);
        }
      } on FileSystemException {
        tmpState = 'The partial copy could NOT be discarded and is '
            'still at ${tmpDest.path}';
      }
      _logger.warn(
        'Could not copy the built app into $dest'
        '${stderr.isEmpty ? '' : ': $stderr'}. '
        '$tmpState. Any previously saved bundle was left in place.',
      );
      return false;
    }
    try {
      if (destDir.existsSync()) {
        destDir.deleteSync(recursive: true);
      }
      tmpDest.renameSync(dest);
    } on FileSystemException catch (e) {
      // The copy landed but the swap did not (dest occupied by a
      // plain file or dangling symlink, permissions). Discard the
      // full-size temp the cp-failure branch already discards —
      // without this, a failed rename parks a hundreds-of-MB bundle
      // under build/ until the next run's cleanup. The dest report
      // is derived, not assumed: unlike the cp branch, the old
      // bundle here may be gone (delete succeeded, rename did not).
      // followLinks: false so a dangling symlink still reads as an
      // occupant (it blocks every retry until removed by hand).
      final destState = Directory(dest).existsSync()
          ? 'The previously saved bundle may no longer be intact.'
          : FileSystemEntity.typeSync(dest, followLinks: false) !=
                  FileSystemEntityType.notFound
              ? 'Whatever occupied that path was left as-is — remove '
                  'it first, or every retry will fail the same way.'
              : 'No previously saved bundle remains at that path.';
      // Clean up FIRST and report what actually happened: the same
      // permissions problem that failed the rename plausibly fails
      // the delete, and claiming a hundreds-of-MB copy was
      // discarded while it sits on disk would be a lie.
      var tmpState = 'The fresh copy was discarded';
      try {
        if (tmpDest.existsSync()) {
          tmpDest.deleteSync(recursive: true);
        }
      } on FileSystemException {
        tmpState = 'The fresh copy could NOT be discarded and is '
            'still at ${tmpDest.path}';
      }
      _logger.warn(
        'Copied the built app but could not swap it into $dest: $e. '
        '$tmpState — re-run the release to retry the save. '
        '$destState',
      );
      return false;
    }

    _logger.info('');
    _logger.success('Saved baseline app: $dest');
    _logger.info('  Embedded baseline ID: $baselineId');
    _logger.info(
      '  If installing manually on device, re-sign the saved '
      'app bundle recursively after any framework repair.',
    );
    return true;
  }
}
