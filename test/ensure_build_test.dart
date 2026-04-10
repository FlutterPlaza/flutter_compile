import 'dart:io';

import 'package:flutter_compile/src/version.dart';
import 'package:test/test.dart';

void main() {
  test('packageVersion matches pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml is missing a version: line');
    final pubspecVersion = match!.group(1);
    expect(
      packageVersion,
      pubspecVersion,
      reason: 'lib/src/version.dart is out of sync with pubspec.yaml. '
          'Bump both together when cutting a release.',
    );
  });
}
