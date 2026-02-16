## flutter_compile

[![Build][build_badge]][build_link]
[![codecov][codecov_badge]][codecov_link]
[![Pub Version][pub_badge]][pub_link]
[![License: BSD-3][license_badge]][license_link]
[![Dart][dart_badge]][dart_link]

A Dart CLI for Flutter contributors and power users. Automates contributor environment setup (framework, DevTools, engine), manages multiple Flutter SDK versions side-by-side, and wraps the engine build/run/test cycle into simple commands.

---

## Getting Started

```sh
dart pub global activate flutter_compile
```

Or from source:

```sh
dart pub global activate --source=path <path to this package>
```

**Requirements:** macOS or Linux, git, python3

---

## SDK Management

Install and manage multiple Flutter SDK versions side-by-side — by version tag or channel.

```sh
# Install a specific version or channel
flutter_compile sdk install 3.19.0
flutter_compile sdk install stable
flutter_compile sdk install beta

# List all installed SDKs
flutter_compile sdk list

# Remove an SDK
flutter_compile sdk remove 3.19.0
```

SDKs are stored in `~/.flutter_compile/versions/<version>/`.

---

## Contributor Environment Setup

One-command setup for Flutter framework, DevTools, and engine contributor environments. Replaces the multi-step wiki guides.

### `install` (alias: `i`)

```sh
flutter_compile install flutter    # Framework contributor environment
flutter_compile install devtools   # DevTools contributor environment
flutter_compile install engine     # Engine contributor environment (default: host platform)
flutter_compile install engine --platform android
```

The engine install automates:
- depot_tools installation and PATH configuration
- `.gclient` file generation with your fork URL
- `gclient sync` (streams output — takes 20-40 min on first run)
- Git remote setup (upstream = flutter/engine, origin = your fork)

### `uninstall` (aliases: `delete`, `remove`)

```sh
flutter_compile uninstall flutter
flutter_compile uninstall devtools
flutter_compile uninstall engine    # optionally removes depot_tools too
```

### `switch` (alias: `s`)

Toggle your PATH between the contributor-built Flutter (from `install flutter`) and your system Flutter installation.

```sh
flutter_compile switch             # Toggle to whichever isn't active
flutter_compile switch compiled    # Use the contributor-built Flutter
flutter_compile switch normal      # Use your system Flutter
```

---

## Engine Workflow

Build, run, and test with a locally-built Flutter engine.

### `build engine` (alias: `b`)

```sh
flutter_compile build engine                              # Host platform, debug, unoptimized
flutter_compile build engine --platform android --cpu arm64
flutter_compile build engine --platform ios --simulator
flutter_compile build engine --mode release --no-unoptimized
flutter_compile build engine --gn                         # Force GN re-run
flutter_compile build engine --no-gn                      # Skip GN step
flutter_compile build engine --clean                      # Clean build
```

GN is auto-skipped on incremental rebuilds when `build.ninja` already exists.

### `run` (alias: `r`)

Run a Flutter app with a local engine build.

```sh
flutter_compile run
flutter_compile run -p android -c arm64
flutter_compile run -p ios --simulator -- -d "iPhone 15"
```

Everything after `--` is forwarded to `flutter run`.

### `test` (alias: `t`)

Run Flutter tests with a local engine build.

```sh
flutter_compile test
flutter_compile test -p android -c arm64
flutter_compile test -- test/my_widget_test.dart
```

Everything after `--` is forwarded to `flutter test`.

### `clean` (alias: `c`)

```sh
flutter_compile clean                        # List builds with sizes
flutter_compile clean host_debug_unopt_arm64  # Delete a specific build
flutter_compile clean --all                   # Delete all builds
```

### `status` (alias: `st`)

```sh
flutter_compile status
```

Displays engine path, source directory status, host CPU, available build directories with sizes, and whether the current directory is a Flutter project.

### Engine options

These options are shared by `build engine`, `run`, and `test`:

| Option | Values | Default |
|--------|--------|---------|
| `--platform, -p` | android, ios, macos, linux, web, host | host |
| `--cpu, -c` | arm, arm64, x64 | auto-detected |
| `--mode, -m` | debug, profile, release | debug |
| `--unoptimized` | flag | true |
| `--simulator` | flag (iOS only) | false |

`build engine` also accepts `--clean`, `--gn`, and `--no-gn`.

---

## Configuration & Maintenance

### `config` (alias: `cf`)

```sh
flutter_compile config list               # Show all settings
flutter_compile config get engine          # Get a value (flutter, engine, devtools, depot_tools)
flutter_compile config set engine /path    # Set a value
```

### `doctor` (alias: `dr`)

```sh
flutter_compile doctor
```

Reports status of required tools (git, python3, dart, flutter), engine tools (depot_tools, ninja, Xcode), config file, and contributor environments.

### `update` (alias: `up`)

```sh
flutter_compile update
```

### Other

```sh
flutter_compile --version
flutter_compile --help
```

---

## Running Tests

```sh
dart test
```

With coverage:

```sh
dart pub global activate coverage 1.2.0
dart test --coverage=coverage
dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info
genhtml coverage/lcov.info -o coverage/
open coverage/index.html
```

---

[build_badge]: https://github.com/FlutterPlaza/flutter_compile/actions/workflows/flutter_compile.yaml/badge.svg
[build_link]: https://github.com/FlutterPlaza/flutter_compile/actions/workflows/flutter_compile.yaml
[codecov_badge]: https://codecov.io/gh/FlutterPlaza/flutter_compile/branch/main/graph/badge.svg
[codecov_link]: https://codecov.io/gh/FlutterPlaza/flutter_compile
[pub_badge]: https://img.shields.io/pub/v/flutter_compile.svg
[pub_link]: https://pub.dev/packages/flutter_compile
[license_badge]: https://img.shields.io/badge/license-BSD--3-blue.svg
[license_link]: https://opensource.org/licenses/BSD-3
[dart_badge]: https://img.shields.io/badge/dart-%3E%3D3.4.0-blue.svg
[dart_link]: https://dart.dev
