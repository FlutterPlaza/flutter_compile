# Changelog

## 0.3.6

### Changed

- Compatible with all current Android Studio releases, including Android Studio Quail (2026.1)
- Future Android Studio and IntelliJ IDEA updates no longer require waiting for a plugin update

## 0.3.5

### Changed

- Compatible with `flutter_compile` 0.19.0 — the build pipeline internals are now delegated to a private build tool the CLI downloads on first use

## 0.3.4

### Added

- **Supported Flutter Versions section** — Code Push tool window now shows every Flutter version the server supports, with a checkmark on the selected one and right-click Download / Set as Code Push Version actions
- **Patches summary row** — total patch count across releases rendered directly under the App node
- **Copy Patch ID** — right-click a patch row to copy its ID to the clipboard
- **Init App link** — clickable row appears when no app is configured, launching `fcp codepush init` in a terminal
- Uses a new `fcp codepush versions --json` CLI subcommand for the supported-versions data

### Changed

- **Browser-only Code Push login** — the Login action now opens a terminal running `fcp codepush login` (no API key dialog); the view auto-refreshes once authentication completes
- CLI bridge parses the new `logged_in`, `total_patches`, and patch-id fields from `codepush status --json`

## 0.3.3

### Added

- **Channel support** — patches can target `beta` or `production` channels
- Compatible with CLI v0.14.0

### Fixed

- Release `--build` no longer reports failure after successful builds

## 0.3.2

### Added

- **Code Push tree panel** — view account, app, releases, and patches in the tool window
- **Code Push actions** — Login, Release, Patch, Rollback from the Tools menu and context menus
- **Code Push CLI integration** — all operations delegate to `fcp codepush` commands

### Changed

- Updated Code Push actions to use `fcp codepush` CLI commands
- Multi-platform artifact support

## 0.3.0

### Added

- **SDK Manager mode dropdown** — "Mode:" combo box in the tool window toolbar to switch between Native and FVM backends
- **Enhanced CLI integration** — new `sdk list --json --mode fvm` support for FVM backend
- **Improved CLI availability check** — richer notification with version display and install instructions
- **Doctor install actions** — wrench button on failing checks to trigger install or configuration
- **Engine Builds improvements** — enhanced tree rendering with disk sizes and build target details

### Changed

- All SDK operations (list, global, use, remove, install) now route through the selected backend mode
- Settings page updated with SDK Manager mode selector
- Tool window panels refresh automatically on mode change

## 0.2.0

Major GUI overhaul — feature parity with the VS Code extension.

### Added

- **SDK tree view** — replaces plain JList with a tree using status icons (green check, package, plugin), right-click context menu (Set as Global, Pin to Project, Open SDK Folder, Remove SDK), and double-click to set global
- **Doctor tree view** — replaces raw text JTextArea with a two-level tree grouped by category (Required Tools, Engine Tools, Configuration, Environments) with pass/fail/warning icons and summary counts
- **Engine Builds tree view** — new tab showing engine path, source status, host CPU, and build targets with disk sizes
- **Per-tab refresh buttons** — each of the three tabs has its own refresh button in the toolbar
- **Remove SDK action** — with confirmation dialog (Tools menu and right-click)
- **Pin SDK to Project action** — writes `.flutter-version` via `sdk use` (Tools menu and right-click)
- **Open SDK Folder action** — reveals SDK directory in system file manager (Tools menu and right-click)
- **Refresh All action** — refreshes all three panels at once (Tools menu)
- **`.flutter-version` file watcher** — auto-refreshes SDK tree when the file is created, changed, or deleted
- **CLI availability check** — notification balloon on project open if `flutter_compile` is not on PATH, with install link
- **Custom tool window icon** — matches the Flutter Compile icon from the VS Code extension
- **`doctor --json` parsing** — structured doctor output via new CLI method
- **`status --json` parsing** — engine status via new CLI method
- **`sdk remove` support** — new CLI method
- **`sdk use` support** — new CLI method for project pinning
- **`--version` check** — new CLI method for availability detection

### Changed

- Tool window now uses `JBTabbedPane` with three tabs (SDKs, Doctor, Engine Builds) instead of two tabs with basic widgets
- Upgraded Gradle IntelliJ Plugin from 1.x (`org.jetbrains.intellij` 1.17.2) to 2.x (`org.jetbrains.intellij.platform` 2.11.0)
- Upgraded Gradle wrapper from 8.5 to 8.13

## 0.1.0

Initial release.

### Added

- Toolbar combo box to switch between installed Flutter SDKs
- Tool window with SDK list (JList) and Doctor output (JTextArea)
- Automatic Flutter SDK path update in IntelliJ project settings on switch
- Install SDK action with version input dialog
- Doctor action to run diagnostics
- Settings page for CLI path configuration
