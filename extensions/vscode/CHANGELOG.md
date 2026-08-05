# Changelog

## 0.3.6

### Changed

- Version alignment with the Android Studio plugin release; no functional changes

## 0.3.5

### Changed

- Compatible with `flutter_compile` 0.19.0 — the build pipeline internals are now delegated to a private build tool the CLI downloads on first use
- `Code Push: Release` no longer offers the deterministic toggle; deterministic builds are now the default inside the build tool

## 0.3.4

### Added

- **Supported Flutter Versions section** — new top-level node in the Code Push view lists every Flutter version the code push server supports, with a star on the selected one and inline Download / Set as Code Push Version actions
- **Patches summary row** — shows total patch count across releases directly under the App node when an app is configured
- **Copy Patch ID** — context menu entry on patch rows copies the ID to the clipboard
- Backed by a new `fcp codepush versions --json` CLI subcommand

### Changed

- **Browser-only Code Push login** — `Code Push: Login` now opens a terminal running `fcp codepush login` and removes the API key prompt; the view auto-refreshes when the terminal exits cleanly
- `codepush account --json` and `codepush status --json` now return structured JSON (with `logged_in`, `total_patches`, and `--release-id` filtering) so the tree can render reliably

## 0.3.3

### Added

- **Channel support** — patches can target `beta` or `production` channels
- Compatible with CLI v0.14.0

### Fixed

- Release `--build` no longer reports failure after successful builds

## 0.3.2

### Added

- **Code Push tree view** — account status, current app, releases list, and patches per release in the sidebar
- **Code Push commands** — Login, Init, Release, Patch, Rollback available from the Command Palette and tree view
- **Code Push status** — view rollout percentages and active/inactive patch status

### Changed

- Updated all Code Push commands to invoke `fcp codepush` CLI
- Multi-platform artifact support

## 0.3.0

### Added

- **Dual SDK backend** — switch between Native and FVM SDK management via the `flutterCompile.sdkManager` setting
- **SDK Manager toggle button** — swap-arrows icon in the SDKs view title bar opens a QuickPick to switch between Native and FVM modes
- **Mode label** — SDKs view title shows "SDKs — Native" or "SDKs — FVM" to indicate the active backend
- **Doctor install actions** — wrench button on failing checks to auto-install or configure missing tools (ninja, Xcode CLI, depot_tools, Python, git, `.flutter_compilerc`, contributor environments)
- **Doctor uninstall action** — trash button on passing environment checks to uninstall contributor environments
- **Engine build command** — build the Flutter engine with platform, mode, and flag selection from the sidebar
- **Engine init command** — initialize engine environment from the Engine Builds view
- **Delete build action** — inline trash button and context menu to delete engine build outputs
- **Switch SDK Manager command** — `Flutter Compile: Switch SDK Manager` available from the Command Palette
- Commands: Initialize Engine, Build Engine, Delete Build, Install/Configure Doctor Check, Uninstall Environment

### Changed

- SDK tree view, status bar, and file watcher now use the pluggable backend system (native or FVM)
- Configuration change listener reloads backend and refreshes all views automatically

## 0.2.0

### Added

- **SDK tree view** — browse installed SDKs with status icons (green check, package, beaker)
- **Inline actions** — Set Global and Remove buttons directly on each SDK row
- **Context menu** — right-click for Pin to Project and Open SDK Folder
- **Doctor tree view** — grouped diagnostic checks (Required Tools, Engine Tools, Configuration, Environments) with pass/fail/warning icons and summary counts
- **Engine Builds tree view** — engine path, source status, host CPU, and build targets with disk sizes
- **Status bar** — always-visible SDK indicator with yellow warning when no SDK is set; click to open quick picker
- **File watcher** — auto-refreshes SDK tree and status bar when `.flutter-version` changes externally
- **CLI availability check** — notification with install link on activation if `flutter_compile` is not found
- **Automatic `dart.flutterSdkPath` updates** — workspace settings update immediately on SDK switch
- Commands: Install SDK, Select/Switch SDK, Doctor, Set Global SDK, Pin to Project, Remove SDK, Open SDK Folder, Refresh SDKs, Refresh Doctor, Refresh Builds, Refresh All

## 0.1.0

Initial release.

### Added

- Basic SDK list and switch via Command Palette
- Doctor command with raw text output
- Status bar showing current global SDK version
