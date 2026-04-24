import 'dart:io';

const String kGeneratedIosPatchEntryFilename = '.fcp_patch_entry.dart';

final RegExp _codePushPatchPattern = RegExp(
  r'(^|\n)\s*[A-Za-z_<>\?\[\], ]+\s+codePushPatch\s*\(',
  multiLine: true,
);

List<String> findCodePushPatchSourceCandidates({
  String libDirPath = 'lib',
}) {
  final libDir = Directory(libDirPath);
  if (!libDir.existsSync()) return const <String>[];

  final libRoot = _normalizePath(libDir.absolute.path);
  final results = <String>[];

  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;

    final absolutePath = _normalizePath(entity.absolute.path);
    final relativePath = _relativeToLibRoot(
      absolutePath: absolutePath,
      libRoot: libRoot,
    );
    if (relativePath == null || _isGeneratedPatchEntry(relativePath)) continue;

    String contents;
    try {
      contents = entity.readAsStringSync();
    } catch (_) {
      continue;
    }

    if (_codePushPatchPattern.hasMatch(contents)) {
      results.add('lib/$relativePath');
    }
  }

  results.sort();
  return results;
}

String buildGeneratedIosPatchEntrypoint({
  required String importPath,
  String? patchSourcePath,
}) {
  // On iOS, cross-library DirectCall from the wrapper to codePushPatch()
  // fails because new functions in overlapping libraries can't be resolved
  // in the bytecode constant pool at runtime.  Work around this by
  // inlining the patch source directly into the wrapper — making main()
  // and codePushPatch() part of the same library.
  if (patchSourcePath != null) {
    final sourceFile = File(patchSourcePath);
    if (sourceFile.existsSync()) {
      var source = sourceFile.readAsStringSync();

      // Rewrite relative imports: the wrapper lives at lib/ but the
      // source may be in a subdirectory (e.g. lib/screens/).  Relative
      // imports like `import 'foo.dart'` need to become
      // `import 'screens/foo.dart'` so they resolve from lib/.
      final sourceDir = _normalizePath(
          sourceFile.parent.path.replaceFirst(RegExp(r'^lib/?'), ''));
      if (sourceDir.isNotEmpty) {
        source = source.replaceAllMapped(
          RegExp(r'''(import\s+['"])(?!dart:|package:)([^'"]+['"])'''),
          (m) => '${m.group(1)}$sourceDir/${m.group(2)}',
        );
        source = source.replaceAllMapped(
          RegExp(r'''(export\s+['"])(?!dart:|package:)([^'"]+['"])'''),
          (m) => '${m.group(1)}$sourceDir/${m.group(2)}',
        );
        source = source.replaceAllMapped(
          RegExp(r'''(part\s+['"])(?!dart:|package:)([^'"]+['"])'''),
          (m) => '${m.group(1)}$sourceDir/${m.group(2)}',
        );
      }

      return "// Generated inline wrapper — do not edit.\n"
          "// Source: $importPath\n\n"
          "$source\n\n"
          "@pragma('dyn-module:entry-point')\n"
          "Object? main() => codePushPatch();\n";
    }
  }
  // Fallback: cross-library import (works on non-iOS, may fail on iOS).
  return "import '$importPath';\n\n"
      "@pragma('dyn-module:entry-point')\n"
      "Object? main() => codePushPatch();\n";
}

String? importPathForPatchSource(String sourcePath) {
  final file = File(sourcePath);
  if (!file.existsSync()) return null;

  final absolutePath = _normalizePath(file.absolute.path);
  final libRoot = _normalizePath(Directory('lib').absolute.path);
  final relativePath = _relativeToLibRoot(
    absolutePath: absolutePath,
    libRoot: libRoot,
  );
  return relativePath;
}

bool _isGeneratedPatchEntry(String relativePath) {
  return relativePath == kGeneratedIosPatchEntryFilename ||
      relativePath.endsWith('/$kGeneratedIosPatchEntryFilename');
}

String _normalizePath(String path) => path.replaceAll('\\', '/');

String? _relativeToLibRoot({
  required String absolutePath,
  required String libRoot,
}) {
  if (absolutePath == libRoot) return null;
  final prefix = '$libRoot/';
  if (!absolutePath.startsWith(prefix)) return null;
  return absolutePath.substring(prefix.length);
}
