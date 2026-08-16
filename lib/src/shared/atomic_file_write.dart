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
///    keep clean). EXCEPTION: an absent target has no mode to
///    preserve — the recreated file lands at the umask default
///    (deliberate: inventing a mode would be a worse guess).
/// 4. Stale dot-prefixed temps from a killed earlier run are swept
///    best-effort first (single-writer assumption — two concurrent
///    builds in one project are unsupported anyway).
///
/// COST of the temp+rename shape (the trade behind properties 1-3):
/// replacement needs write+execute on the target's DIRECTORY and
/// nothing on the file — the inverse of an in-place write. A
/// writable file inside a read-only directory (e.g. ios/Runner/ at
/// 0555 with a 0644 Info.plist), which the old writers could stamp,
/// now throws at temp creation. Deliberate: an EACCES fallback to an
/// in-place write would reopen property 2's truncate-on-ENOSPC hole.
/// Callers already treat the throw as "unstamped build", never as a
/// tool crash. Sibling cost: rename replaces the INODE, so the
/// target's owner becomes the writing process's user where an
/// in-place write preserved it — a sudo run leaves the file
/// root-owned for the next unprivileged run (which then hits the
/// throw above).
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
    for (final stale in parent.listSync(followLinks: false)) {
      final name = stale.path.split(RegExp(r'[/\\]')).last;
      if (!(name.startsWith('.$base.') && name.endsWith('.tmp'))) {
        continue;
      }
      // Links swept as links (a dangling temp symlink is invisible
      // to File.existsSync — the same blindness the saved-baseline
      // temp cleanup covers); directories are not ours, skipped.
      if (stale is Link || stale is File) {
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
  // No pure-Dart chmod exists; POSIX-only, and Windows ACLs are not
  // mode bits — the rename default is correct there. A missing chmod
  // binary (ProcessException) and a non-zero exit (mode-bit-less
  // filesystem, SELinux denial) degrade rather than fail a write that
  // would succeed: the content is the load-bearing half of the
  // contract. Degrade landing spots: the named causes are systemic
  // and fail BOTH calls → temp default mode; the faithful-mode
  // chmod alone failing (asymmetric transient, e.g. fork EAGAIN)
  // leaves the file at the already-applied 0600 clamp (owner-only —
  // tighter than the target was, unreported by design); the clamp
  // alone failing ends at the faithful mode, correct anyway.
  void chmodTemp(String octal) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', [octal, tempFile.path]);
    } on ProcessException {
      // Degrade, per above.
    }
  }

  try {
    // Create empty and clamp to owner-only BEFORE the content lands:
    // the temp sits in the target's own directory, and a 0600
    // target's contents must not be world-readable even for the
    // duration of the write. The faithful target mode is applied
    // after the content, so a read-only (0444) target still restores.
    tempFile.writeAsStringSync('');
    if (mode != null) {
      chmodTemp('600');
    }
    tempFile.writeAsStringSync(content);
    if (mode != null) {
      chmodTemp(mode.toRadixString(8));
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
