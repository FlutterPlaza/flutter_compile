import 'package:flutter_compile/src/commands/codepush_commands/_codepush_init.dart';
import 'package:test/test.dart';

/// The exact header a pre-fix CLI generated. Written out in full rather
/// than composed from the production constants: an upgrade test built
/// out of the same strings it is checking would keep passing if both
/// sides drifted together.
const _legacyScaffold = '''
package com.example.demo

import io.flutter.app.FlutterApplication
import java.io.File

class CodePushApp : FlutterApplication() {
    override fun onCreate() {
        // Copy codepush.yaml from assets to files dir before Flutter engine init.
        try {
            val dest = File(filesDir, "codepush.yaml")
            assets.open("codepush.yaml").use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        } catch (e: Exception) {
            android.util.Log.e("CodePushApp", "Failed to copy codepush.yaml", e)
        }
        super.onCreate()
    }
}
''';

/// The even older shape: v1 embedding AND the exists-guarded copy.
const _oldestScaffold = '''
package com.example.demo

import io.flutter.app.FlutterApplication
import java.io.File

class CodePushApp : FlutterApplication() {
    override fun onCreate() {
        // Copy codepush.yaml from assets to files dir before Flutter engine init.
        try {
            val dest = File(filesDir, "codepush.yaml")
            if (!dest.exists()) {
                assets.open("codepush.yaml").use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            }
        } catch (_: Exception) {}
        super.onCreate()
    }
}
''';

void main() {
  group('codePushAppKotlinSource', () {
    final source = codePushAppKotlinSource('com.example.demo');

    test('extends android.app.Application, not the deprecated v1 shim', () {
      expect(source, contains('import android.app.Application'));
      expect(source, contains('class CodePushApp : Application()'));
      expect(source, isNot(contains('io.flutter.app.FlutterApplication')));
      expect(source, isNot(contains('FlutterApplication()')));
    });

    test('keeps the package, the File import and the copy body', () {
      expect(source, startsWith('package com.example.demo\n'));
      expect(source, contains('import java.io.File'));
      expect(source, contains(kCodePushAppCopyBlock));
    });

    test(
        'copies the config BEFORE super.onCreate() — the engine reads it '
        'during FlutterJNI init', () {
      expect(
        source.indexOf('assets.open("codepush.yaml")'),
        lessThan(source.indexOf('super.onCreate()')),
      );
    });

    test('the copy is unguarded, so a store update refreshes the config', () {
      expect(source, isNot(contains('if (!dest.exists())')));
    });
  });

  group('upgradeCodePushAppSource', () {
    test('migrates the deprecated base class in an otherwise current file', () {
      final upgraded = upgradeCodePushAppSource(_legacyScaffold);

      expect(upgraded, isNotNull);
      expect(upgraded!.source, isNot(contains('FlutterApplication')));
      expect(upgraded.source, contains('import android.app.Application'));
      expect(upgraded.source, contains('class CodePushApp : Application()'));
      expect(upgraded.notes, hasLength(1));
      expect(upgraded.notes.single, contains('android.app.Application'));
    });

    test('applies both migrations to the oldest shape, one note each', () {
      final upgraded = upgradeCodePushAppSource(_oldestScaffold);

      expect(upgraded, isNotNull);
      expect(upgraded!.notes, hasLength(2));
      expect(upgraded.source, contains(kCodePushAppCopyBlock));
      expect(upgraded.source, isNot(contains('if (!dest.exists())')));
      expect(upgraded.source, isNot(contains('FlutterApplication')));
    });

    test(
        'the freshly generated file is a fixed point — repeat init runs '
        'rewrite nothing', () {
      expect(
        upgradeCodePushAppSource(codePushAppKotlinSource('com.example.demo')),
        isNull,
      );
    });

    test('leaves a hand-modified file alone when only half the pair matches',
        () {
      // A renamed class still referencing the old base: swapping the
      // import alone would strand the FlutterApplication reference.
      const modified = '''
package com.example.demo

import io.flutter.app.FlutterApplication
import java.io.File

class MyApp : FlutterApplication() {
$kCodePushAppCopyBlock
}
''';

      expect(upgradeCodePushAppSource(modified), isNull);
    });

    test('an upgrade is idempotent — its own output needs no second pass', () {
      final once = upgradeCodePushAppSource(_oldestScaffold)!.source;

      expect(upgradeCodePushAppSource(once), isNull);
    });
  });

  group('upgradeCodePushAppSource on a CRLF checkout', () {
    // Git for Windows defaults to core.autocrlf=true, so a committed
    // CodePushApp.kt comes back CRLF. Byte-exact gates split on that:
    // the single-line embedding pair still matched while the
    // multi-line copy block never did.
    String crlf(String source) => source.replaceAll('\n', '\r\n');

    test('applies both migrations, exactly as it does on LF', () {
      final upgraded = upgradeCodePushAppSource(crlf(_oldestScaffold));

      expect(upgraded, isNotNull);
      expect(upgraded!.notes, hasLength(2));
      expect(upgraded.source, isNot(contains('if (!dest.exists())')));
      expect(upgraded.source, isNot(contains('FlutterApplication')));
      expect(
        upgraded.source.replaceAll('\r\n', '\n'),
        contains(kCodePushAppCopyBlock),
      );
    });

    test('hands the file back in the endings it arrived with', () {
      final upgraded = upgradeCodePushAppSource(crlf(_oldestScaffold))!;

      expect(upgraded.source, contains('\r\n'));
      expect(
        upgraded.source.replaceAll('\r\n', ''),
        isNot(contains('\n')),
        reason: 'no bare LF should survive in a CRLF file',
      );
    });

    test(
        'the current file is still a fixed point — a CRLF checkout must '
        'not be rewritten, nor warned about, on every re-run', () {
      final current = crlf(codePushAppKotlinSource('com.example.demo'));

      expect(upgradeCodePushAppSource(current), isNull);
      expect(codePushAppNeedsCopyFix(current), isFalse);
      expect(reconcileCodePushAppSource(current).warnings, isEmpty);
    });
  });

  group('reconcileCodePushAppSource', () {
    test('a current file needs nothing said about it', () {
      final outcome = reconcileCodePushAppSource(
        codePushAppKotlinSource('com.example.demo'),
      );

      expect(outcome.source, isNull);
      expect(outcome.notes, isEmpty);
      expect(outcome.warnings, isEmpty);
      expect(outcome.summary, contains('already configured'));
    });

    test('the oldest shape migrates cleanly and warns about nothing', () {
      final outcome = reconcileCodePushAppSource(_oldestScaffold);

      expect(outcome.source, isNotNull);
      expect(outcome.notes, hasLength(2));
      expect(outcome.warnings, isEmpty);
      expect(outcome.summary, contains('Updated'));
    });

    test(
        'an embedding-only rewrite still warns about a hand-edited copy '
        'body — the two migrations are independent, and chaining them '
        'let the frozen-config bug survive under an "Updated" line', () {
      // Legacy embedding pair, plus a copy body that is neither the
      // legacy one nor the current one (an extra log line).
      const handEdited = '''
package com.example.demo

import io.flutter.app.FlutterApplication
import java.io.File

class CodePushApp : FlutterApplication() {
    override fun onCreate() {
        try {
            val dest = File(filesDir, "codepush.yaml")
            if (!dest.exists()) {
                android.util.Log.d("CodePushApp", "first run")
                assets.open("codepush.yaml").use { input ->
                    dest.outputStream().use { output -> input.copyTo(output) }
                }
            }
        } catch (_: Exception) {}
        super.onCreate()
    }
}
''';

      final outcome = reconcileCodePushAppSource(handEdited);

      expect(outcome.source, isNotNull, reason: 'the embedding is migrated');
      expect(outcome.notes, hasLength(1));
      expect(outcome.warnings, contains(kCodePushAppCopyFixWarning));
      expect(kCodePushAppCopyFixWarning, contains('has been modified'));
      // The summary is the LAST thing printed about this file, after
      // "✓ Android configured". Reporting it as done under a warning
      // that says the CLI could not fix it is what undercuts the
      // warning.
      expect(outcome.summary, contains('manual fix'));
      expect(outcome.summary, isNot(contains('already configured')));
    });

    test(
        'the half-migrated pair is left alone but no longer silent — the '
        'deprecated base class is named', () {
      const renamedClass = '''
package com.example.demo

import io.flutter.app.FlutterApplication
import java.io.File

class MyApp : FlutterApplication() {
$kCodePushAppCopyBlock
}
''';

      final outcome = reconcileCodePushAppSource(renamedClass);

      expect(outcome.source, isNull, reason: 'leaving it alone is right');
      expect(outcome.warnings, [kCodePushAppLegacyEmbeddingWarning]);
      expect(outcome.warnings.single, contains(kCodePushAppSuperclass));
      // No rewrite happened, so the old summary said "already
      // configured" — for a file the CLI had just declined to fix.
      expect(outcome.summary, contains('manual fix'));
      expect(outcome.summary, isNot(contains('already configured')));
    });

    test('a CRLF copy of the current file warns about nothing', () {
      final outcome = reconcileCodePushAppSource(
        codePushAppKotlinSource('com.example.demo').replaceAll('\n', '\r\n'),
      );

      expect(outcome.warnings, isEmpty);
      expect(outcome.source, isNull);
      expect(outcome.summary, contains('already configured'));
    });
  });

  group('defaultAppNameFrom', () {
    test('uses the directory name', () {
      expect(
          defaultAppNameFrom(Uri.parse('file:///home/me/my_app/')), 'my_app');
      // No trailing slash: the last segment is still the name.
      expect(defaultAppNameFrom(Uri.parse('file:///home/me/my_app')), 'my_app');
    });

    test('a POSIX root has no name to take', () {
      expect(defaultAppNameFrom(Uri.parse('file:///')), 'app');
    });

    test('a Windows drive root falls back too — "C:" is not a name', () {
      // `Directory('C:\\').uri` is `file:///C:/`, whose only non-empty
      // segment is the drive designator. The POSIX root already fell
      // back here; this is the narrow case the URI fix itself targets.
      expect(defaultAppNameFrom(Uri.parse('file:///C:/')), 'app');
      expect(defaultAppNameFrom(Uri.parse('file:///c:/')), 'app');
    });

    test('a directory ON a drive keeps its own name', () {
      expect(defaultAppNameFrom(Uri.parse('file:///C:/src/my_app/')), 'my_app');
      // A directory literally named "C:" one level down is not a drive
      // root, so it is a real (if odd) name.
      expect(defaultAppNameFrom(Uri.parse('file:///src/C:/')), 'C:');
    });
  });

  group('scaffold constants', () {
    test(
        'name the v2-embedding base class — the manual instructions '
        'interpolate these, so both places move together', () {
      expect(kCodePushAppImport, 'import android.app.Application');
      expect(kCodePushAppSuperclass, 'class CodePushApp : Application()');
    });
  });
}
