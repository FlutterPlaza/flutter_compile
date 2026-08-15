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
