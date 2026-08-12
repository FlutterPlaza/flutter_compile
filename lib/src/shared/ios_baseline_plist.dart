import 'dart:io';

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

  plistFile.writeAsStringSync(content);
  return originalContent;
}

void restoreIosInfoPlist(
  String originalContent, {
  String plistPath = kDefaultIosInfoPlistPath,
}) {
  File(plistPath).writeAsStringSync(originalContent);
}

const String kDefaultBuiltIosAppPath = 'build/ios/iphoneos/Runner.app';

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
