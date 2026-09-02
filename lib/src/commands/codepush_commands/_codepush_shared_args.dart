// Shared boundary-argument rules for the code push commands (one
// body per rule, so the two commands cannot drift).

import 'package:flutter_compile/src/shared/codepush_client.dart';
import 'package:mason_logger/mason_logger.dart';

/// Every `--platform` value the code push commands understand: the
/// six documented ones plus 'android', the alias the patch command's
/// local-hash fallback has always accepted. 'android' is neither
/// advertised in the error text below nor accepted under `--build`
/// (see [normalizeCodePushPlatformArg]'s `forBuild`) — it is
/// forwarded to `flutter build <platform>`, which has no such
/// subcommand, so a `--build` run would pay a full engine
/// preparation (artifact download on a cold cache) only to fail in
/// flutter's own usage error.
const knownCodePushPlatforms = {
  'apk',
  'appbundle',
  'android',
  'ios',
  'linux',
  'macos',
  'windows',
};

/// Normalizes (trim, case-fold) and validates a raw `--platform`
/// value, SHARED by the patch and release commands so the two answer
/// the same question the same way. Every downstream platform gate is
/// an exact-string compare that fails open — on patch, a wrong-cased
/// value silently dropped the device-side baseline check; on
/// release, it skipped the baseline-identity requirement and the
/// Android packaged-lib rule. A value the commands do not understand
/// must be a fast exit, never a silent miss. Returns
/// `(normalized, error)`; a non-null error means exit 64.
(String?, String?) normalizeCodePushPlatformArg(
  String? raw, {
  required bool forBuild,
}) {
  if (raw == null) return (null, null);
  final trimmed = raw.trim();
  // Present-but-blank is REJECTED, not treated as absent — the same
  // rule as an empty --signing-key: an unset CI variable expanding
  // to '' must fail fast, not silently become "no platform named"
  // (on patch that can mean an upload with no baseline identity; on
  // release, a dual-platform prompt telling the operator to pass
  // the flag they passed).
  if (trimmed.isEmpty) {
    return (
      null,
      'Empty --platform value (an unset CI variable?). Use one of: '
          'apk, appbundle, ios, linux, macos, windows — or drop the flag.',
    );
  }
  final normalized = trimmed.toLowerCase();
  if (!knownCodePushPlatforms.contains(normalized)) {
    return (
      null,
      'Unknown --platform "$trimmed". Use one of: '
          'apk, appbundle, ios, linux, macos, windows.',
    );
  }
  // The alias is understood for the no-build paths only; a value
  // the command understands for one purpose and cannot act on for
  // the other must still be a fast exit under --build.
  if (forBuild && normalized == 'android') {
    return (
      null,
      "--platform android is not a buildable target; use 'apk' or "
          "'appbundle' with --build.",
    );
  }
  return (normalized, null);
}

/// What both build-capable commands print when the pre-flight session
/// probe comes back rejected. One body so the two name the same remedy;
/// worded to say WHEN the check happened, because the whole point of
/// the check is that the operator has not paid for a build yet.
const String kExpiredSessionMessage =
    'The server rejected your saved login. Run "fcp codepush login" and '
    'retry — checked before the build starts, so an expired session no '
    'longer costs you a full build.';

/// Pre-flight the stored login BEFORE a command spends a build on it.
/// Returns the exit code the command must return, or null to continue.
///
/// One shared body: both build-capable commands paid the same cost (a
/// full `flutter build`, then a 401 at the upload), and both must fail
/// on exactly the one verdict that is evidence — an explicit rejection.
/// [SessionCheck.unknown] is deliberately NOT a refusal: an offline or
/// slow server would otherwise turn a saving into a new outage, and the
/// upload still checks the token for real.
Future<int?> refuseOnExpiredSession({
  required CodePushClient client,
  required String token,
  required Logger logger,
}) async {
  final session = await client.checkSession(token: token);
  switch (session) {
    case SessionCheck.expired:
      logger.err(kExpiredSessionMessage);
      return ExitCode.software.code;
    case SessionCheck.unknown:
      logger.detail(
        'Could not verify the saved login before building; continuing '
        '(the upload verifies it for real).',
      );
      return null;
    case SessionCheck.valid:
      logger.detail('Saved login accepted by the server.');
      return null;
  }
}

/// Filters a repeatable option's entries: whitespace-only entries
/// (an unset CI variable) are dropped; kept values are UNTRIMMED —
/// a `--dart-define` value is compiled into both the release
/// baseline and its patches, and the two commands must bake
/// IDENTICAL constants (trimming on one side silently diverged a
/// release from its own patch). One shared body so the two commands
/// cannot drift, pinned directly.
List<String> nonBlankEntries(List<String>? entries) => [
      for (final value in entries ?? const <String>[])
        if (value.trim().isNotEmpty) value,
    ];
