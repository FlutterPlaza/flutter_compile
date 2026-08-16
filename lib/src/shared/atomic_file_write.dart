import 'dart:io';

/// Replaces [path]'s contents atomically, writing through symlinks.
/// The ONE mechanism behind every stamp/restore write (iOS
/// Info.plist, Android codepush.yaml) — collapsed here so the two
/// writers cannot drift apart again. Four properties, each
/// load-bearing somewhere:
///
/// 1. The spelled path is resolved through symlinks FIRST and the
///    rename lands on the physical target: rename at the spelled
///    path would replace the LINK itself, so one stamp/restore pair
///    on a checkout with a symlinked shared config would destroy
///    the wiring and strand the stamped bytes in the old target.
/// 2. Temp + rename in the target's own directory: a bare write
///    truncates BEFORE writing, so a mid-write failure (ENOSPC
///    right after a build filled the disk) would leave the target
///    EMPTY — and on a stamp path the exception unwinds before the
///    caller has stored the original, so the only good copy would
///    die with the stack frame. Same-directory keeps the rename
///    atomic (same volume by construction).
/// 3. The target's mode survives: renameSync installs the temp's
///    default mode, which would silently rewrite a 0600 or
///    group-writable file across a stamp/restore cycle (and where
///    git tracks the exec bit, dirty the repo the restore exists to
///    keep clean).
/// 4. Stale dot-prefixed temps from a killed earlier run are swept
///    best-effort first (single-writer assumption — two concurrent
///    builds in one project are unsupported anyway).
///
/// Temps are dot-prefixed so a leftover never looks like the real
/// file to anything; for targets under Android assets/ the dot
/// prefix additionally falls under AAPT's default
/// ignoreAssetsPattern, so a leftover can never ship in the APK.
void atomicReplaceFileContents(String path, String content) {
  String target;
  try {
    target = File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    // Nonexistent or unresolvable (e.g. a dangling link): write
    // as-spelled. Recreating the file is the best available outcome
    // — callers gate on existence themselves where absence means
    // "skip" — and this is the ONE branch where a link at the path
    // is replaced rather than written through (it points at
    // nothing, so there is nothing to preserve).
    target = path;
  }
  final parent = File(target).parent;
  final base = target.split(RegExp(r'[/\\]')).last;
  try {
    for (final stale in parent.listSync().whereType<File>()) {
      final name = stale.uri.pathSegments.last;
      if (name.startsWith('.$base.') && name.endsWith('.tmp')) {
        stale.deleteSync();
      }
    }
  } on FileSystemException {
    // The sweep is best-effort only.
  }
  final stat = File(target).statSync();
  final mode =
      stat.type == FileSystemEntityType.notFound ? null : stat.mode & 0xFFF;
  final tempFile = File('${parent.path}/.$base.$pid.tmp');
  try {
    tempFile.writeAsStringSync(content);
    if (mode != null && !Platform.isWindows) {
      // No pure-Dart chmod exists; POSIX-only, and Windows ACLs are
      // not mode bits — the rename default is correct there.
      try {
        Process.runSync('chmod', [mode.toRadixString(8), tempFile.path]);
      } on ProcessException {
        // No chmod binary at all: degrade to the temp's default
        // mode rather than failing a write that would succeed.
      }
    }
    tempFile.renameSync(target);
  } on FileSystemException {
    try {
      tempFile.deleteSync();
    } on FileSystemException {
      // Best-effort cleanup; the target is untouched either way.
    }
    rethrow;
  }
}
