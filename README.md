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

After activation, both `flutter_compile` and the shorter `fcp` alias are available:

```sh
fcp sdk list          # same as flutter_compile sdk list
fcp sync flutter      # same as flutter_compile sync flutter
```

**Requirements:** macOS, Linux, or Windows; git, python3. On Windows, Visual Studio with C++ workload is required for engine builds.

---

## Quick Reference

Every command at a glance. Detailed usage follows below.

| Command | Alias | Description |
|---------|-------|-------------|
| `install flutter` | `i flutter` | Clone flutter/flutter, set up git remotes, run `update-packages` |
| `install devtools` | `i devtools` | Clone flutter/devtools, configure PATH for `devtools_tool` |
| `install engine` | `i engine` | Install depot_tools, generate `.gclient`, run `gclient sync`, set up remotes |
| `uninstall <env>` | `delete`, `remove` | Remove an installed contributor environment and clean up config |
| `switch [mode]` | `s` | Toggle PATH between contributor-built Flutter and system Flutter |
| `sync` | `sy` | Sync **all** contributor environments with upstream in one shot |
| `sync flutter` | `sy flutter` | `git fetch upstream` + `git rebase upstream/master` + `flutter update-packages` |
| `sync engine` | `sy engine` | `git fetch upstream` + `git rebase upstream/main` + `gclient sync` |
| `sync devtools` | `sy devtools` | `git fetch upstream` + `git rebase upstream/master` |
| `build engine` | `b engine` | Run GN + ninja to compile the Flutter engine for a target platform |
| `run` | `r` | Run a Flutter app using a locally-built engine |
| `test` | `t` | Run Flutter tests using a locally-built engine |
| `clean` | `c` | List or delete engine build output directories |
| `status` | `st` | Show engine path, available builds, host CPU, project detection |
| `sdk install <ver>` | | Install a Flutter SDK by version tag or channel name |
| `sdk list` | `sdk ls` | List all installed SDKs with global/project markers |
| `sdk remove <ver>` | | Delete an installed SDK and clean up config if needed |
| `sdk global [ver]` | | Set or show the global default SDK version |
| `sdk use [ver]` | | Pin or show the per-project SDK version (`.flutter-version`) |
| `sdk exec <cmd>` | | Run any command through the resolved SDK (project -> global) |
| `config list` | `cf list` | Display all `~/.flutter_compilerc` entries |
| `config get <key>` | `cf get` | Read a single config value |
| `config set <k> <v>` | `cf set` | Write a config value |
| `daemon` | | Start a JSON-RPC 2.0 daemon for IDE communication |
| `ui` | | Open the terminal UI dashboard |
| `doctor` | `dr` | Health-check required tools, config file, and contributor environments |
| `update` | `up` | Self-update flutter_compile to the latest pub version |

---

## SDK Management

Install and manage multiple Flutter SDK versions side-by-side — by version tag or channel. Each SDK gets its own isolated `PUB_CACHE` to avoid snapshot incompatibility.

### `sdk install` — Install an SDK

Downloads and installs a Flutter SDK. The first install automatically becomes the global default.

```sh
flutter_compile sdk install 3.19.0    # Specific version tag
flutter_compile sdk install stable    # Channel name
flutter_compile sdk install beta
```

SDKs are stored in `~/flutter_compile/versions/<version>/`, each with its own `.pub-cache` directory.

### `sdk list` (alias: `ls`) — List installed SDKs

Shows all installed SDK versions with their paths. Marks which version is set as the global default and which is pinned to the current project.

```sh
flutter_compile sdk list
# Output:
#   3.19.0    /Users/you/flutter_compile/versions/3.19.0  (global)
#   stable    /Users/you/flutter_compile/versions/stable   (project)
```

### `sdk global` — Set or show global default

Sets the global default SDK version. This is the version used when no project-level `.flutter-version` file exists. Running without an argument shows the current global version.

```sh
flutter_compile sdk global 3.19.0     # Set 3.19.0 as the global default
flutter_compile sdk global            # Show current global version
```

Setting a global version updates your shell config (`~/.zshrc` / `~/.bashrc`) with the SDK `bin/` directory and an isolated `PUB_CACHE`.

### `sdk use` — Pin a version per project

Creates a `.flutter-version` file in the current directory. When `sdk exec` is used from this directory, it picks up the pinned version instead of the global default.

```sh
flutter_compile sdk use 3.19.0        # Pin 3.19.0 for this project
flutter_compile sdk use               # Show currently pinned version
```

### `sdk exec` — Run commands through the resolved SDK

Executes any command using the resolved Flutter SDK. Resolution order: project `.flutter-version` first, then global default.

This is the key command for multi-version workflows — it ensures `flutter`, `dart`, and any other SDK tool run from the correct version without manually switching PATH.

```sh
flutter_compile sdk exec flutter doctor
flutter_compile sdk exec dart analyze
flutter_compile sdk exec flutter build apk
flutter_compile sdk exec dart run build_runner build
```

The resolved SDK's `bin/` is prepended to PATH and its isolated `PUB_CACHE` is set, so all tools (flutter, dart, pub) operate in the correct version context.

### `sdk remove` — Remove an installed SDK

Deletes the SDK directory. If you remove the current global default, the rc config and shell PATH block are cleaned up automatically.

```sh
flutter_compile sdk remove 3.19.0
```

---

## Contributor Environment Setup

One-command setup for Flutter framework, DevTools, and engine contributor environments. Replaces the multi-step wiki guides.

### `install` (alias: `i`) — Set up a contributor environment

Each subcommand clones the relevant repository, configures git remotes (upstream = flutter org, origin = your fork), and performs environment-specific setup.

**`install flutter`** — Clones flutter/flutter, sets up git remotes, runs `flutter update-packages`, and optionally configures IDE settings for IntelliJ.

**`install devtools`** — Clones flutter/devtools, configures git remotes, and adds `devtools_tool` to your PATH.

**`install engine`** — The most involved setup. Installs depot_tools (Google's build toolchain), generates a `.gclient` configuration pointing to your engine fork, runs `gclient sync` (20-40 min on first run), and configures git remotes.

```sh
flutter_compile install flutter
flutter_compile install devtools
flutter_compile install engine
flutter_compile install engine --platform android
```

### `uninstall` (aliases: `delete`, `remove`) — Remove a contributor environment

Removes the cloned repository directory, cleans PATH exports from your shell config, and removes the path entry from `~/.flutter_compilerc`.

```sh
flutter_compile uninstall flutter
flutter_compile uninstall devtools
flutter_compile uninstall engine      # Optionally removes depot_tools too
```

### `switch` (alias: `s`) — Toggle Flutter PATH

Toggles your PATH between the contributor-built Flutter (from `install flutter`) and your normal system Flutter installation. Useful when you want to quickly move between contributing to the framework and using a release Flutter.

```sh
flutter_compile switch             # Toggle to whichever isn't active
flutter_compile switch compiled    # Use the contributor-built Flutter
flutter_compile switch normal      # Use your system Flutter
```

After switching, restart your terminal or `source` your shell config for the change to take effect.

---

## Sync

Keep contributor environments up to date with upstream. Each sync subcommand fetches the latest changes from the upstream Flutter organization and rebases your local branch on top.

### `sync` (alias: `sy`) — Sync all environments

When run without a subcommand, syncs all three environments sequentially. Each environment is synced independently — if one fails, the others still run. A summary at the end reports which succeeded and which failed.

```sh
flutter_compile sync
# Syncs flutter, engine, and devtools in order.
# Reports: "Synced: flutter, devtools" / "Failed: engine"
```

### `sync flutter` — Sync the framework

Fetches from upstream, rebases on `upstream/master`, and runs `flutter update-packages` to keep dependencies current.

```sh
flutter_compile sync flutter
```

### `sync engine` — Sync the engine

Fetches from upstream in the `src/flutter` subdirectory, rebases on `upstream/main`, then runs `gclient sync` to update all engine dependencies. After syncing, prints a reminder to rebuild.

```sh
flutter_compile sync engine
# → "Run "flutter_compile build engine" to rebuild."
```

### `sync devtools` — Sync DevTools

Fetches from upstream and rebases on `upstream/master`.

```sh
flutter_compile sync devtools
```

Each sync subcommand reads its install path from `~/.flutter_compilerc`. If an environment hasn't been installed yet, it prints an error suggesting you run `install` first.

---

## Engine Workflow

Build, run, and test with a locally-built Flutter engine. These commands wrap the GN + ninja build system and the `--local-engine` flags so you don't have to remember them.

### `build engine` (alias: `b`) — Compile the engine

Runs GN (flag resolution) then ninja (compilation) for the specified target. GN is auto-skipped on incremental rebuilds when `build.ninja` already exists in the output directory.

```sh
flutter_compile build engine                              # Host platform, debug, unoptimized
flutter_compile build engine --platform android --cpu arm64
flutter_compile build engine --platform ios --simulator
flutter_compile build engine --mode release --no-unoptimized
flutter_compile build engine --gn                         # Force GN re-run
flutter_compile build engine --no-gn                      # Skip GN step entirely
flutter_compile build engine --clean                      # Clean build (removes output dir first)
```

### `run` (alias: `r`) — Run with local engine

Runs a Flutter app using your locally-built engine. Automatically resolves `--local-engine` and `--local-engine-src-path` from your config and the last build target.

```sh
flutter_compile run
flutter_compile run -p android -c arm64
flutter_compile run -p ios --simulator -- -d "iPhone 15"
```

Everything after `--` is forwarded to `flutter run`.

### `test` (alias: `t`) — Test with local engine

Runs Flutter tests using your locally-built engine, with the same automatic `--local-engine` resolution as `run`.

```sh
flutter_compile test
flutter_compile test -p android -c arm64
flutter_compile test -- test/my_widget_test.dart
```

Everything after `--` is forwarded to `flutter test`.

### `clean` (alias: `c`) — Manage build outputs

Lists engine build directories with their disk sizes, or deletes specific builds.

```sh
flutter_compile clean                        # List builds with sizes
flutter_compile clean host_debug_unopt_arm64  # Delete a specific build
flutter_compile clean --all                   # Delete all builds
```

### `status` (alias: `st`) — Show engine status

Displays engine configuration: engine path, source directory status, host CPU architecture, available build directories with disk sizes, and whether the current directory contains a Flutter project.

```sh
flutter_compile status
# Engine path: /Users/you/flutter_compile/engine
# Source dir:  /Users/you/flutter_compile/engine/src [OK]
# Host CPU:    arm64
#
# Available builds:
#   host_debug_unopt_arm64         4.2G
#   android_debug_unopt_arm64      2.1G
#
# Flutter project: yes (pubspec.yaml found)
```

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

### `config` (alias: `cf`) — Manage settings

Read and write `~/.flutter_compilerc`, the central config file that stores paths to contributor environments, depot_tools, and the global SDK version.

**`config list`** — Show all stored key-value pairs.

**`config get <key>`** — Read a single value. Accepts friendly names (`flutter`, `engine`, `devtools`, `depot_tools`, `global_sdk`) which map to their internal key names.

**`config set <key> <value>`** — Write a value. Useful for manually correcting paths if you moved a directory.

```sh
flutter_compile config list
flutter_compile config get engine
flutter_compile config set engine /new/path/to/engine
```

### `doctor` (alias: `dr`) — Health check

Checks that required tools are installed (git, python3, dart, flutter), engine tools are available (gclient, ninja, Xcode on macOS), `~/.flutter_compilerc` is valid, and each contributor environment has correct git remotes (upstream + origin).

```sh
flutter_compile doctor
# [+] git is installed
# [+] python3 is installed
# [+] dart is installed
# [+] flutter is installed
# [+] depot_tools (gclient) is installed
# [+] ninja is installed
# [+] .flutter_compilerc is valid
# [+] Flutter contributor environment: installed
# [-] DevTools contributor environment: not configured
# [+] Engine contributor environment: installed
```

### `update` (alias: `up`) — Self-update

Checks pub.dev for a newer version of flutter_compile and updates if available.

```sh
flutter_compile update
```

### JSON Output

Several commands support `--json` for machine-readable output, useful for IDE extensions and scripting:

```sh
flutter_compile sdk list --json        # JSON array of installed SDKs
flutter_compile doctor --json          # Health checks as JSON array
flutter_compile config list --json     # Config as JSON object
flutter_compile status --json          # Engine status as JSON object
```

### Other

```sh
flutter_compile --version
flutter_compile --help
```

---

## Daemon

The `daemon` command starts a JSON-RPC 2.0 server over stdin/stdout, enabling IDE extensions to communicate with the CLI in real time instead of spawning one-off processes.

```sh
echo '{"jsonrpc":"2.0","method":"version","id":1}' | flutter_compile daemon
```

Each JSON-RPC message is a single line of JSON (same convention as `flutter daemon`).

**Available methods:**

| Method | Description |
|--------|-------------|
| `sdk.list` | List installed SDKs |
| `sdk.global.get` | Get global SDK version |
| `sdk.global.set` | Set global SDK version |
| `sdk.use.get` | Get project SDK version |
| `sdk.use.set` | Set project SDK version |
| `doctor` | Run health checks |
| `config.list` | List all config values |
| `config.get` | Get a config value |
| `config.set` | Set a config value |
| `status` | Get engine status |
| `version` | Get CLI version |
| `shutdown` | Stop the daemon |

**Notifications (server to client):**
- `daemon.connected` — sent on startup with version and PID
- `sdk.changed` — sent when global or project SDK version changes
- `config.changed` — sent when `.flutter_compilerc` changes

---

## Terminal UI

The `ui` command opens an interactive terminal dashboard for SDK management without needing an IDE.

```sh
flutter_compile ui
```

**Tabs:**
- **SDKs** — view installed SDKs, set global default (Enter), install new SDK (i)
- **Environments** — view contributor environment status
- **Builds** — view available engine builds
- **Doctor** — view health check results

**Keyboard shortcuts:**
- `1-4` — switch tabs
- Arrow keys — navigate within a tab
- `Tab` — cycle tabs
- `i` — install SDK (on SDKs tab)
- `r` — refresh data
- `q` / `Esc` — quit

---

## VS Code Extension

A companion VS Code extension lives in `extensions/vscode/`. It provides:

- **Status bar** — shows the active Flutter SDK version. Click to open a quick pick switcher.
- **Commands** — `Flutter Compile: Install SDK`, `Flutter Compile: Switch SDK`, `Flutter Compile: Doctor` available from the command palette.
- **Auto-update** — switching SDK automatically sets `dart.flutterSdkPath` in workspace settings so the Dart extension picks up the new SDK.
- **File watcher** — watches `.flutter-version` for external changes (e.g. from the CLI) and updates the status bar and settings automatically.

### Install from source

```sh
cd extensions/vscode
npm install
npm run compile
```

Then press `F5` in VS Code to launch an Extension Development Host, or package with `vsce package`.

The extension requires `flutter_compile` to be installed and available on PATH. You can configure a custom path via the `flutterCompile.cliPath` setting.

---

## Android Studio / IntelliJ Plugin

A companion IntelliJ platform plugin lives in `extensions/intellij/`. It provides:

- **Toolbar combo box** — SDK version switcher in the main toolbar. Shows the current global SDK and lets you switch with a single click.
- **Tool window** — "Flutter Compile" tool window with two tabs:
  - **SDKs** — lists all installed SDK versions with global/project markers, Switch and Refresh buttons.
  - **Doctor** — runs `flutter_compile doctor` and displays the output.
- **Auto-update** — switching SDK automatically updates the Flutter SDK path in project settings via the Flutter IntelliJ plugin's API.
- **Settings** — configure the path to the `flutter_compile` CLI under **Settings > Tools > Flutter Compile**.
- **Actions** — `Install SDK` and `Doctor` available from the Tools menu and Find Action dialog.

### Build from source

```sh
cd extensions/intellij
./gradlew buildPlugin
```

The built plugin ZIP will be in `build/distributions/`. Install it via **Settings > Plugins > Install Plugin from Disk**.

Requires the [Dart](https://plugins.jetbrains.com/plugin/6351-dart) and [Flutter](https://plugins.jetbrains.com/plugin/9212-flutter) plugins to be installed.

---

## Shell Completions

flutter_compile supports tab completion for commands, subcommands, and flags in bash, zsh, and fish shells.

### Install completions

```sh
flutter_compile completion install
```

This writes the completion script for your current shell. After installation, restart your terminal or source your shell config.

### Uninstall completions

```sh
flutter_compile completion uninstall
```

Once installed, you can use `<Tab>` to complete:

- Commands: `flutter_compile <Tab>` shows `install`, `build`, `sdk`, `sync`, etc.
- Subcommands: `flutter_compile sdk <Tab>` shows `install`, `list`, `global`, etc.
- Flags: `flutter_compile build engine --<Tab>` shows `--platform`, `--cpu`, `--mode`, etc.

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
