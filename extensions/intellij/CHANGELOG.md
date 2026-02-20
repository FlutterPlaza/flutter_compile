# Changelog

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
