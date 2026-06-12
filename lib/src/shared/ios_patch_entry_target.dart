import 'dart:io';

const String kGeneratedIosPatchEntryFilename = '.fcp_patch_entry.dart';

final RegExp _codePushPatchPattern = RegExp(
  r'(^|\n)\s*[A-Za-z_<>\?\[\], ]+\s+codePushPatch\s*\(',
  multiLine: true,
);

List<String> findCodePushPatchSourceCandidates({String libDirPath = 'lib'}) {
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
  bool useImportWrapper = false,
}) {
  // When useImportWrapper is true (swap mode), emit a cross-library
  // import wrapper so the patch source stays as its own library and
  // overlaps with the baseline AOT class. This enables the swap loop
  // to replace existing functions at runtime. Requires the engine's
  // cross-library constant pool repair.
  if (useImportWrapper) {
    return "import '$importPath';\n\n"
        "@pragma('dyn-module:entry-point')\n"
        "Object? main() => codePushPatch();\n";
  }
  // Default: inline the patch source into the wrapper library.
  // This avoids cross-library DirectCall entirely but produces a
  // new library (no overlap, no function swap).
  if (patchSourcePath != null) {
    final sourceFile = File(patchSourcePath);
    if (sourceFile.existsSync()) {
      var source = sourceFile.readAsStringSync();

      // Rewrite relative imports: the wrapper lives at lib/ but the
      // source may be in a subdirectory (e.g. lib/screens/).  Relative
      // imports like `import 'foo.dart'` need to become
      // `import 'screens/foo.dart'` so they resolve from lib/.
      final sourceDir = _normalizePath(
        sourceFile.parent.path.replaceFirst(RegExp(r'^lib/?'), ''),
      );
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
