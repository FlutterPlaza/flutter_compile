# Flutter Compile — IntelliJ / Android Studio Plugin

Manage multiple Flutter SDK versions, run diagnostics, and monitor engine builds from IntelliJ IDEA or Android Studio. Supports both **Native** and **FVM** backends.

## Prerequisites

| Requirement | How to install |
|---|---|
| **flutter_compile CLI** | `dart pub global activate flutter_compile` |
| IntelliJ IDEA or Android Studio **2025.1+** | [jetbrains.com](https://www.jetbrains.com/idea/) |
| **Dart** plugin | Bundled with Android Studio, or install from JetBrains Marketplace |
| **Flutter** plugin | Bundled with Android Studio, or install from JetBrains Marketplace |

> The CLI must be on your `PATH`. Run `flutter_compile --version` to verify.

## Installation

### From JetBrains Marketplace

1. **Settings** > **Plugins** > **Marketplace**
2. Search **Flutter Compile**
3. Click **Install** and restart

### From Disk

1. Download `.zip` from [Releases](https://github.com/flutterplaza/flutter_compile/releases)
2. **Settings** > **Plugins** > gear icon > **Install Plugin from Disk...**

---

## Walkthrough

![IntelliJ Plugin Walkthrough](https://raw.githubusercontent.com/FlutterPlaza/flutter_compile/main/assets/intellij_fcp.gif)

---

## Features

### SDK Manager

![SDK Manager](https://raw.githubusercontent.com/FlutterPlaza/flutter_compile/main/assets/intellij-sdk-manager.png)

Browse, switch, pin, and remove Flutter SDKs from the **SDKs** tab in the Flutter Compile tool window.

| Icon | Meaning |
|---|---|
| Green checkmark | Active SDK (global or project-pinned) |
| Package icon | Installed but inactive |
| Plugin icon | Locally compiled contributor build |

**Toolbar:** Install (`+`), Refresh. **Right-click:** Set Global, Pin to Project, Open Folder, Remove. **Double-click** to set global.

### Mode Dropdown (Native / FVM)

![Mode Dropdown](https://raw.githubusercontent.com/FlutterPlaza/flutter_compile/main/assets/intellij-mode-dropdown.png)

A **"Mode:"** dropdown in the tool window toolbar lets you switch between **Native** and **FVM** SDK backends. All SDK operations route through the selected backend.

### Doctor

![Doctor](https://raw.githubusercontent.com/FlutterPlaza/flutter_compile/main/assets/intellij-doctor-engine.png)

Grouped diagnostic checks (Required Tools, Engine Tools, Configuration, Environments) with pass/fail icons and summary counts. Click the wrench icon on failing checks to install or configure.

### Engine Builds

![Engine Builds](https://raw.githubusercontent.com/FlutterPlaza/flutter_compile/main/assets/intellij-engine-builds.png)

Engine path, source status, host CPU, and build targets with disk sizes. Delete builds from the context menu.

### Toolbar Combo Box

SDK version switcher in the main toolbar. Shows the current global SDK — click to switch instantly.

### File Watcher

Watches `.flutter-version` files. External changes are picked up immediately.

### Automatic SDK Path Updates

Switching SDKs updates the Flutter SDK path in IntelliJ project settings via the Flutter plugin API.

---

## Menu Actions

| Menu Item | Description |
|---|---|
| Install Flutter SDK... | Install a new SDK version or channel |
| Flutter Compile Doctor | Run diagnostics and show tool window |
| Remove Flutter SDK... | Choose and remove an installed SDK |
| Pin Flutter SDK to Project... | Pin an SDK to the current project |
| Open Flutter SDK Folder... | Reveal SDK directory in file manager |
| Refresh Flutter Compile | Refresh all panels |

## Settings

**Settings** > **Tools** > **Flutter Compile**:

| Setting | Default | Description |
|---|---|---|
| CLI Path | `flutter_compile` | Path to the CLI executable |
| SDK Manager Mode | `Native` | Backend mode: Native or FVM |

## Troubleshooting

| Problem | Solution |
|---|---|
| "flutter_compile CLI not found" | Install: `dart pub global activate flutter_compile`. Ensure `~/.pub-cache/bin` is in PATH. |
| SDK tree is empty | Click Refresh. Run `flutter_compile sdk list` in a terminal. |
| Doctor shows all red | Run `flutter_compile doctor` in a terminal. |
| Toolbar combo shows "(none)" | Use **Set as Global** from the SDK tree context menu. |
| Plugin not visible | Ensure Dart and Flutter plugins are installed and enabled. |

## Building from Source

```sh
cd extensions/intellij
./gradlew build     # compile and package
./gradlew runIde    # launch sandbox IDE with plugin
```

Requires JDK 17+ and Gradle 8.13+.

## License

BSD-3-Clause. See [LICENSE](https://github.com/flutterplaza/flutter_compile/blob/main/extensions/intellij/LICENSE).
