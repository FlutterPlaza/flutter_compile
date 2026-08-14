/// Filenames shared between the build service (writer), the release
/// command (path composition), and the archive service (destination) —
/// deliberately independent of the build service so the archive does
/// not have to import it for two strings.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The canonical spec filename: the ARCHIVE destination. The build
/// directory itself uses content-addressed names (see
/// [interfaceSpecFilenameFor]) so a spec change always changes the
/// front-end option string — the build fingerprint includes the option
/// string, not the file's bytes, so a same-path spec with new contents
/// would be silently ignored by a cached kernel step.
const String kInterfaceSpecFilename = 'dynamic_interface.yaml';

/// Prefix shared by the canonical name and every content-addressed
/// name; the writer sweeps `<prefix>*.yaml` before writing so the
/// build directory holds exactly one spec.
const String kInterfaceSpecFilenamePrefix = 'dynamic_interface';

/// The content-addressed filename for a spec with [yamlContent].
String interfaceSpecFilenameFor(String yamlContent) {
  final digest = sha256.convert(utf8.encode(yamlContent)).toString();
  return '${kInterfaceSpecFilenamePrefix}_${digest.substring(0, 8)}.yaml';
}

/// The front end's detailed interface report (the compiler's own
/// account of what it guarded — evidence, where the spec is intent).
const String kInterfaceReportFilename = 'dynamic_interface_report.json';
