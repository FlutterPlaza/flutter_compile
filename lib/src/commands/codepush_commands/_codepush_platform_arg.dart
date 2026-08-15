/// Every `--platform` value the code push commands understand: the
/// six documented ones plus 'android', the alias the patch command's
/// local-hash fallback has always accepted. 'android' is deliberately
/// NOT advertised in the error text below — under `--build` it is
/// forwarded to `flutter build <platform>`, which has no such
/// subcommand, so recommending it would send a mistyping operator
/// into a guaranteed build failure.
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
(String?, String?) normalizeCodePushPlatformArg(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return (null, null);
  final normalized = trimmed.toLowerCase();
  if (!knownCodePushPlatforms.contains(normalized)) {
    return (
      null,
      'Unknown --platform "$trimmed". Use one of: '
          'apk, appbundle, ios, linux, macos, windows.',
    );
  }
  return (normalized, null);
}
