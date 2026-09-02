import 'dart:io';

import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:flutter_compile/src/shared/functions.dart';
import 'package:test/test.dart';

import '../../helpers/temp_home.dart';

/// The signing keypair's location, and the migration that keeps an
/// upgrading user's key from being silently replaced.
///
/// Platform-independent by construction: `F.homeDir()` and
/// `F.legacyHomeDir()` are both redirected, so the Windows shape (a
/// keypair under the old `HOME`-derived path, an empty
/// `%USERPROFILE%`) is reproducible on any host.
void main() {
  final tempHome = TempHome();
  late Directory legacyHome;

  String privateKeyIn(String dir) =>
      '$dir/${CodePushClient.signingPrivateKeyName}';
  String publicKeyIn(String dir) =>
      '$dir/${CodePushClient.signingPublicKeyName}';

  void writeKeypair(String dir, String marker) {
    Directory(dir).createSync(recursive: true);
    File(privateKeyIn(dir)).writeAsStringSync('PRIVATE $marker');
    File(publicKeyIn(dir)).writeAsStringSync('PUBLIC $marker');
  }

  setUp(() {
    tempHome.setUp();
    legacyHome = Directory.systemTemp.createTempSync('fc_legacy_home_');
    F.legacyHomeDirOverride = legacyHome.path;
  });

  tearDown(() {
    tempHome.tearDown();
    if (legacyHome.existsSync()) legacyHome.deleteSync(recursive: true);
  });

  group('signingKeyDir', () {
    test('follows F.homeDir, which is USERPROFILE on Windows', () {
      expect(
        CodePushClient.signingKeyDir(),
        '${tempHome.path}/.flutter_codepush',
      );
    });

    test('the legacy dir is null when it names the same directory', () {
      F.legacyHomeDirOverride = tempHome.path;
      expect(CodePushClient.legacySigningKeyDir(), isNull);
    });

    test('the legacy dir is the old HOME-derived path when they differ', () {
      expect(
        CodePushClient.legacySigningKeyDir(),
        '${legacyHome.path}/.flutter_codepush',
      );
    });
  });

  group('resolveSigningKeyDir', () {
    test(
        'is the canonical dir when nothing exists yet — that is where a '
        'new keypair belongs', () {
      expect(
        CodePushClient.resolveSigningKeyDir(),
        CodePushClient.signingKeyDir(),
      );
    });

    test('prefers the canonical dir when both hold a key', () {
      writeKeypair(CodePushClient.signingKeyDir(), 'new');
      writeKeypair(CodePushClient.legacySigningKeyDir()!, 'old');

      expect(
        CodePushClient.resolveSigningKeyDir(),
        CodePushClient.signingKeyDir(),
      );
    });

    test('falls back to the legacy dir when only it holds a key', () {
      writeKeypair(CodePushClient.legacySigningKeyDir()!, 'old');

      expect(
        CodePushClient.resolveSigningKeyDir(),
        CodePushClient.legacySigningKeyDir(),
      );
    });
  });

  group('migrateLegacySigningKey', () {
    test('copies both halves and leaves the originals in place', () {
      final legacy = CodePushClient.legacySigningKeyDir()!;
      writeKeypair(legacy, 'old');

      final result = CodePushClient.migrateLegacySigningKey();

      expect(result.outcome, SigningKeyMigrationOutcome.migrated);
      expect(result.fromDir, legacy);
      expect(result.toDir, CodePushClient.signingKeyDir());

      final target = CodePushClient.signingKeyDir();
      expect(File(privateKeyIn(target)).readAsStringSync(), 'PRIVATE old');
      expect(File(publicKeyIn(target)).readAsStringSync(), 'PUBLIC old');
      // Copy, not move: a half-finished migration must still leave the
      // user with the key the server knows.
      expect(File(privateKeyIn(legacy)).existsSync(), isTrue);
      // And every default now resolves to the canonical location.
      expect(CodePushClient.resolveSigningKeyDir(), target);
    });

    test('the private half alone is enough to migrate', () {
      final legacy = CodePushClient.legacySigningKeyDir()!;
      Directory(legacy).createSync(recursive: true);
      File(privateKeyIn(legacy)).writeAsStringSync('PRIVATE old');

      final result = CodePushClient.migrateLegacySigningKey();

      expect(result.outcome, SigningKeyMigrationOutcome.migrated);
      expect(
        File(privateKeyIn(CodePushClient.signingKeyDir())).existsSync(),
        isTrue,
      );
    });

    test('never overwrites a key already at the canonical location', () {
      writeKeypair(CodePushClient.signingKeyDir(), 'new');
      writeKeypair(CodePushClient.legacySigningKeyDir()!, 'old');

      final result = CodePushClient.migrateLegacySigningKey();

      expect(result.outcome, SigningKeyMigrationOutcome.nothingToDo);
      expect(
        File(privateKeyIn(CodePushClient.signingKeyDir())).readAsStringSync(),
        'PRIVATE new',
      );
    });

    test(
        'nothing to do when the two directories are the same — the POSIX '
        'case with HOME set', () {
      F.legacyHomeDirOverride = tempHome.path;
      writeKeypair(CodePushClient.signingKeyDir(), 'new');

      expect(
        CodePushClient.migrateLegacySigningKey().outcome,
        SigningKeyMigrationOutcome.nothingToDo,
      );
    });

    test('nothing to do when the legacy directory holds no key', () {
      expect(
        CodePushClient.migrateLegacySigningKey().outcome,
        SigningKeyMigrationOutcome.nothingToDo,
      );
    });

    test('reports failure rather than leaving the caller to re-key', () {
      final legacy = CodePushClient.legacySigningKeyDir()!;
      writeKeypair(legacy, 'old');
      // A regular file where the target directory has to go: creating
      // it throws, which is the shape of any unwritable-home failure.
      File(CodePushClient.signingKeyDir()).writeAsStringSync('not a dir');

      final result = CodePushClient.migrateLegacySigningKey();

      expect(result.outcome, SigningKeyMigrationOutcome.failed);
      expect(result.fromDir, legacy);
      expect(result.error, isNotNull);
      // The point of reporting rather than throwing: callers keep using
      // the key the server already verifies against, instead of
      // generating a new one and superseding it for shipped builds.
      expect(CodePushClient.resolveSigningKeyDir(), legacy);
    });
  });
}
