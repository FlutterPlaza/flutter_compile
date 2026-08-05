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
