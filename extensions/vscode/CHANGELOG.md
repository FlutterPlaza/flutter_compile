# Changelog

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
