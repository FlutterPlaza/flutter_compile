/// Filenames shared between the build service (writer), the release
/// command (path composition), and the archive service (destination) —
/// deliberately independent of the build service so the archive does
/// not have to import it for two strings.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// The canonical spec filename: the ARCHIVE destination. The build
/// directory itself uses content-addressed names (see
/// [interfaceSpecFilenameFor]) so a spec change always changes the
/// front-end option string — the build fingerprint includes the option
/// string, not the file's bytes, so a same-path spec with new contents
/// would be silently ignored by a cached kernel step.
const String kInterfaceSpecFilename = 'dynamic_interface.yaml';

/// Prefix shared by the canonical name and every content-addressed
/// name. The sweep deletes exactly the names fcp writes (the fixed
/// name or a 16-hex hashed one — see [sweepInterfaceSpecs]), so the
/// build directory holds exactly one fcp-written spec while a
/// user-parked file under a similar name survives.
const String kInterfaceSpecFilenamePrefix = 'dynamic_interface';

/// Whether this run's spec name provably differs from the previous
/// build's ([changed]), provably matches it ([unchanged]), or there
/// was nothing to compare against ([unknown] — an empty directory
/// after a full clean, a wiped build/, or a prior refusal's sweep;
/// also an ambiguous multi-spec sweep).
enum InterfaceSpecChange { changed, unchanged, unknown }

/// Hash width shared by the name builder and the sweep pattern: if
/// they ever disagreed, [sweepInterfaceSpecs] would stop recognising
/// fcp's own specs — stale specs accumulate, the change detection goes
/// permanently unknown, and the one-spec-per-directory invariant
/// quietly stops holding.
const int _specHashHexLength = 16;

/// The content-addressed filename for a spec with [yamlContent].
/// 16 hex chars (64 bits): a collision with any previously built spec
/// would silently reinstate the stale-kernel hazard the addressing
/// exists to prevent — and it is the one failure with no observable
/// signal — so the width is chosen to delete that branch, not to
/// shorten filenames.
String interfaceSpecFilenameFor(String yamlContent) {
  final digest = sha256.convert(utf8.encode(yamlContent)).toString();
  return '${kInterfaceSpecFilenamePrefix}_'
      '${digest.substring(0, _specHashHexLength)}.yaml';
}

/// The exact names fcp itself writes: the legacy fixed name or a
/// content-addressed one. The sweep matches ONLY these, so a spec a
/// user parked under a similar name in build/codepush (the documented
/// user-supplied `--dynamic-interface` escape hatch) is never eaten.
/// The prefix interpolates verbatim — it contains only letters and an
/// underscore, no regex metacharacters — and the dot is hand-escaped:
/// RegExp.escape is a Dart 3.6+ API, newer than this package's
/// declared SDK floor, and an install-time compile error on older
/// SDKs is the one failure pub cannot warn about.
final RegExp _fcpSpecName = RegExp(
  '^$kInterfaceSpecFilenamePrefix'
  '(_[0-9a-f]{$_specHashHexLength})?\\.yaml\$',
);

/// Delete every interface spec fcp itself wrote (hashed or legacy
/// fixed-name) in [dirPath], returning the deleted basenames.
/// Best-effort per entry: one undeletable stale file must not shield
/// the rest, and an unlistable directory is left for the caller's
/// write path to surface. Shared by the writer and the release
/// command's post-report-delete refusal paths, so no refusal leaves a
/// previous run's spec next to an already-deleted report.
List<String> sweepInterfaceSpecs(String dirPath) {
  final swept = <String>[];
  try {
    for (final entity in Directory(dirPath).listSync()) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && _fcpSpecName.hasMatch(name)) {
        try {
          entity.deleteSync();
          swept.add(name);
        } on FileSystemException {
          // Keep sweeping.
        }
      }
    }
  } on FileSystemException {
    // Unlistable: the caller's write path surfaces the real error.
  }
  return swept;
}

/// The front end's detailed interface report (the compiler's own
/// account of what it guarded — evidence, where the spec is intent).
const String kInterfaceReportFilename = 'dynamic_interface_report.json';
