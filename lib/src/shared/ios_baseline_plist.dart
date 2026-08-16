import 'dart:io';

import 'package:flutter_compile/src/shared/atomic_file_write.dart';

import 'package:uuid/uuid.dart';

const String kDefaultIosInfoPlistPath = 'ios/Runner/Info.plist';

String generateBaselineId() => const Uuid().v4();

String? writeBaselineIdToIosInfoPlist(
  String baselineId, {
  String plistPath = kDefaultIosInfoPlistPath,
}) {
  final plistFile = File(plistPath);
  if (!plistFile.existsSync()) return null;

  final originalContent = plistFile.readAsStringSync();
  var content = originalContent;
  const keyTag = '<key>FCPBaselineId</key>';

  if (content.contains(keyTag)) {
    content = content.replaceFirst(
      RegExp(r'<key>FCPBaselineId</key>\s*<string>[^<]*</string>'),
      '$keyTag\n\t<string>$baselineId</string>',
    );
  } else {
    // Insert before the LAST </dict>: the first one may close a nested
    // dict (NSAppTransportSecurity, CFBundleURLTypes, ...) and a key
    // injected there is invisible to the SDK's Info.plist lookup.
    final idx = content.lastIndexOf('</dict>');
    if (idx == -1) return null;
    content = '${content.substring(0, idx)}'
        '\t$keyTag\n\t<string>$baselineId</string>\n</dict>'
        '${content.substring(idx + '</dict>'.length)}';
  }

  _atomicPlistWrite(plistPath, content);
  return originalContent;
}

void restoreIosInfoPlist(
  String originalContent, {
  String plistPath = kDefaultIosInfoPlistPath,
}) {
  _atomicPlistWrite(plistPath, originalContent);
}

/// Both plist halves write through [atomicReplaceFileContents]; the
/// mechanism (link-resolving, atomic, mode-preserving, stale-temp
/// sweeping) and its rationale live on that helper.
void _atomicPlistWrite(String plistPath, String content) =>
    atomicReplaceFileContents(plistPath, content);

const String kDefaultBuiltIosAppPath = 'build/ios/iphoneos/Runner.app';

/// Derives the `.app` bundle directory from a baseline binary path
/// (`<app>/Frameworks/App.framework/App`), or null when the path does
/// not point inside an app bundle. Keeping the identity read pinned to
/// the SAME bundle the uploaded bytes come from is what prevents a
/// stamped id from one build being attached to the binary of another.
String? builtIosAppDirFromBinaryPath(String binaryPath) {
  const suffix = '/Frameworks/App.framework/App';
  if (!binaryPath.endsWith(suffix)) return null;
  return binaryPath.substring(0, binaryPath.length - suffix.length);
}

/// Pure precedence for the baseline identity of an iOS release: the id
/// stamped by this run's `--build`, then the explicit `--baseline-id`
/// flag, then the id read from the built app. Empty strings count as
/// absent. Returns null when no source provides one — the command then
/// errors unless the caller explicitly allowed a missing identity.
String? resolveIosBaselineId({
  String? stampedByBuild,
  String? explicitFlag,
  String? fromBuiltApp,
}) {
  String? nonEmpty(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  return nonEmpty(stampedByBuild) ??
      nonEmpty(explicitFlag) ??
      nonEmpty(fromBuiltApp);
}

/// Reads `FCPBaselineId` from the BUILT app's Info.plist. After
/// `release --build` restores the source plist, the built app is the
/// only place the stamped id survives — this is what lets a later
/// `--no-build` re-release carry the identity of the app it actually
/// ships.
///
/// The built plist is usually binary (Xcode converts it), so `plutil`
/// is tried first; XML plists are parsed directly as a fallback so the
/// helper also works where `plutil` doesn't exist.
String? readBaselineIdFromBuiltAppPlist({
  String appPath = kDefaultBuiltIosAppPath,
}) {
  final plist = File('$appPath/Info.plist');
  if (!plist.existsSync()) return null;
  try {
    final result = Process.runSync(
      'plutil',
      ['-extract', 'FCPBaselineId', 'raw', '-o', '-', plist.path],
    );
    if (result.exitCode == 0) {
      final value = (result.stdout as String).trim();
      if (value.isNotEmpty) return value;
    }
  } catch (_) {
    // plutil unavailable — fall through to XML parsing.
  }
  try {
    final content = plist.readAsStringSync();
    final match = RegExp(
      r'<key>FCPBaselineId</key>\s*<string>([^<]+)</string>',
    ).firstMatch(content);
    final value = match?.group(1)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  } catch (_) {
    return null;
  }
}
