import 'dart:io';

import 'package:flutter_compile/src/shared/functions.dart';

/// Test helper that redirects [F.homeDir] to a temporary directory.
///
/// Usage:
/// ```dart
/// final tempHome = TempHome();
/// setUp(tempHome.setUp);
/// tearDown(tempHome.tearDown);
/// ```
class TempHome {
  late Directory _dir;

  String get path => _dir.path;

  void setUp() {
    _dir = Directory.systemTemp.createTempSync('fc_test_');
    F.homeDirOverride = _dir.path;
  }

  void tearDown() {
    F.homeDirOverride = null;
    // A test that pointed the LEGACY home somewhere must not leak that
    // into the next one — the default (null) makes `legacyHomeDir()`
    // follow `homeDirOverride`, which is what keeps a migration test
    // away from the developer's real `$HOME`.
    F.legacyHomeDirOverride = null;
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}
