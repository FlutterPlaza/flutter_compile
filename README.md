## flutter_compile

![coverage][coverage_badge]
[![style: very good analysis][very_good_analysis_badge]][very_good_analysis_link]
[![License: BSD-3][license_badge]][license_link]

A Dart CLI that automates setting up Flutter framework, DevTools, and Engine contributor development environments. No more following 20-step wiki guides — one command handles depot_tools, gclient sync, git remotes, GN flags, and ninja builds.

---

## Getting Started

Activate globally via [pub](https://pub.dev):

```sh
dart pub global activate flutter_compile
```

Or locally from source:

```sh
dart pub global activate --source=path <path to this package>
```

**Requirements:** macOS or Linux, git, python3

---

## Commands

### `install` — Set up contributor environments

```sh
# Set up Flutter framework development environment
flutter_compile install flutter

# Set up DevTools development environment
flutter_compile install devtools

# Set up Flutter engine development environment (default: host platform)
flutter_compile install engine

# Engine for a specific platform
flutter_compile install engine --platform android
flutter_compile install engine --platform ios
flutter_compile install engine --platform web
```

The engine install automates:
- depot_tools installation and PATH configuration
- `.gclient` file generation with your fork URL
- `gclient sync` (streams output — takes 20-40 min on first run)
- Git remote setup (upstream = flutter/engine, origin = your fork)

### `run` — Run a Flutter app with a local engine (alias: `r`)

```sh
# Run app with default local engine (host_debug_unopt_arm64 on Apple Silicon)
flutter_compile run

# Run targeting a specific engine build
flutter_compile run -p android -c arm64

# Run on iOS simulator, specific device
flutter_compile run -p ios --simulator -- -d "iPhone 15"

# Short alias
flutter_compile r
```

Everything after `--` is forwarded to `flutter run` (e.g. `-d chrome`, `--release`).

**Run options:**

| Option | Values | Default |
|--------|--------|---------|
| `--platform, -p` | android, ios, macos, linux, web, host | host |
| `--cpu, -c` | arm, arm64, x64 | auto-detected |
| `--mode, -m` | debug, profile, release | debug |
| `--unoptimized` | flag | true |
| `--simulator` | flag (iOS only) | false |

### `build` — Build the Flutter engine

```sh
# Build engine for host platform (default: debug, unoptimized)
flutter_compile build engine

# Incremental rebuild (GN auto-skipped if build.ninja exists)
flutter_compile build engine

# Force GN re-run
flutter_compile build engine --gn

# Skip GN explicitly
flutter_compile build engine --no-gn

# Build for Android
flutter_compile build engine --platform android --cpu arm64

# Build for iOS simulator on Apple Silicon
flutter_compile build engine --platform ios --simulator

# Release build
flutter_compile build engine --mode release --no-unoptimized

# Clean build
flutter_compile build engine --clean
```

**Build options:**

| Option | Values | Default |
|--------|--------|---------|
| `--platform, -p` | android, ios, macos, linux, web, host | host |
| `--cpu, -c` | arm, arm64, x64 | auto-detected |
| `--mode, -m` | debug, profile, release | debug |
| `--unoptimized` | flag | true |
| `--simulator` | flag (iOS only) | false |
| `--clean` | flag | false |
| `--gn` | force GN re-run | false |
| `--no-gn` | skip GN step | false |

### `uninstall` — Remove environments

```sh
flutter_compile uninstall flutter
flutter_compile uninstall devtool
flutter_compile uninstall engine    # optionally removes depot_tools too
```

### `doctor` — Check environment health

```sh
flutter_compile doctor
```

Reports status of:
- Required tools (git, python3, dart, flutter)
- Engine tools (depot_tools/gclient, ninja, Xcode on macOS)
- Config file (`.flutter_compilerc`)
- Flutter, DevTools, and Engine contributor environments (directory exists, git remotes configured)

### `switch` — Toggle Flutter installations

```sh
# Toggle between normal and compiled Flutter
flutter_compile switch

# Switch to compiled Flutter
flutter_compile switch compiled

# Switch back to normal Flutter
flutter_compile switch normal
```

### `update` — Update the CLI

```sh
flutter_compile update
```

### Other

```sh
# Show version
flutter_compile --version

# Show help
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

[coverage_badge]: https://github.com/FlutterPlaza/flutter_compile/actions/workflows/main.yaml/badge.svg
[license_badge]: https://img.shields.io/badge/license-BSD--3-blue.svg
[license_link]: https://opensource.org/licenses/BSD-3
[very_good_analysis_badge]: https://img.shields.io/badge/style-very_good_analysis-B22C89.svg
[very_good_analysis_link]: https://pub.dev/packages/very_good_analysis
