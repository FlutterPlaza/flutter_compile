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
    content = content.replaceFirst(
      '</dict>',
      '\t$keyTag\n\t<string>$baselineId</string>\n</dict>',
    );
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
