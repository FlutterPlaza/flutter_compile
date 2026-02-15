/// Resolves GN flags for the Flutter engine build.
///
/// Returns a [List<String>] of arguments to pass to the `gn` tool.
List<String> resolveGnFlags({
  required String platform,
  String? cpu,
  String mode = 'debug',
  bool unoptimized = true,
  bool simulator = false,
  String hostArch = 'x86_64',
}) {
  final flags = <String>[];

  switch (platform) {
    case 'android':
      flags.addAll(['--android', '--android-cpu', cpu ?? 'arm64']);
    case 'ios':
      flags.add('--ios');
      if (simulator) {
        flags.add('--simulator');
        if (hostArch == 'arm64') {
          flags.addAll(['--mac-cpu', 'arm64']);
        }
      }
    case 'macos':
      if (hostArch == 'arm64') {
        flags.addAll(['--mac-cpu', 'arm64']);
      }
    case 'linux':
      break;
    case 'web':
      flags.add('--web');
    case 'host':
      if (hostArch == 'arm64') {
        flags.addAll(['--mac-cpu', 'arm64']);
      }
  }

  if (unoptimized) {
    flags.add('--unoptimized');
  }

  if (mode == 'profile') {
    flags.addAll(['--runtime-mode', 'profile']);
  } else if (mode == 'release') {
    flags.addAll(['--runtime-mode', 'release']);
  }

  return flags;
}

/// Resolves the ninja output directory name for the given build configuration.
String resolveOutputDir({
  required String platform,
  String? cpu,
  String mode = 'debug',
  bool unoptimized = true,
  bool simulator = false,
  String hostArch = 'x86_64',
}) {
  final parts = <String>[];

  switch (platform) {
    case 'android':
      parts.add('android');
    case 'ios':
      parts.add('ios');
    case 'macos':
      parts.add('host');
    case 'linux':
      parts.add('host');
    case 'web':
      parts.add('wasm');
    case 'host':
      parts.add('host');
  }

  parts.add(mode);

  if (simulator && platform == 'ios') {
    parts.add('sim');
  }

  if (unoptimized) {
    parts.add('unopt');
  }

  // Append CPU architecture suffix
  switch (platform) {
    case 'android':
      parts.add(cpu ?? 'arm64');
    case 'ios':
      if (simulator && hostArch == 'arm64') {
        parts.add('arm64');
      }
    case 'macos' || 'host':
      if (hostArch == 'arm64') {
        parts.add('arm64');
      }
    case 'linux':
      if (hostArch == 'arm64') {
        parts.add('arm64');
      }
    case 'web':
      break;
  }

  return parts.join('_');
}
