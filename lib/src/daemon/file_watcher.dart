import 'dart:async';
import 'dart:io';

class FileWatcher {
  FileWatcher({required this.paths, required this.onChanged});

  final List<String> paths;
  final void Function(String path) onChanged;
  final _subscriptions = <StreamSubscription<FileSystemEvent>>[];
  Timer? _debounceTimer;

  void start() {
    for (final path in paths) {
      final file = File(path);
      // Watch parent directory for file creation events
      final parent = file.parent;
      if (parent.existsSync()) {
        final fileName = file.uri.pathSegments.last;
        final sub = parent.watch().listen((event) {
          if (event.path == file.path ||
              event.path.endsWith('/$fileName') ||
              event.path.endsWith('\\$fileName')) {
            _debounce(path);
          }
        });
        _subscriptions.add(sub);
      }
      // Also watch the file itself if it exists
      if (file.existsSync()) {
        final sub = file.watch().listen((event) {
          _debounce(path);
        });
        _subscriptions.add(sub);
      }
    }
  }

  void _debounce(String path) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      onChanged(path);
    });
  }

  void stop() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }
}
