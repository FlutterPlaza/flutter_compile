# Flutter Compile — IntelliJ / Android Studio Plugin

Manage multiple Flutter SDK versions, run diagnostics, and monitor engine builds from IntelliJ IDEA or Android Studio. No terminal needed.

## Prerequisites

| Requirement | How to install |
|---|---|
| **flutter_compile CLI** | `dart pub global activate flutter_compile` |
| IntelliJ IDEA or Android Studio **2025.1+** | [jetbrains.com](https://www.jetbrains.com/idea/) |
| **Dart** plugin | Bundled with Android Studio, or install from JetBrains Marketplace |
| **Flutter** plugin | Bundled with Android Studio, or install from JetBrains Marketplace |

> The CLI must be on your `PATH`. Run `flutter_compile --version` in a terminal to verify.
> If the CLI is missing when you open a project, the plugin will show a notification balloon with a link to installation instructions.

## Installation

### From JetBrains Marketplace

1. Open **Settings** (`Cmd+,` / `Ctrl+Alt+S`)
2. Go to **Plugins** > **Marketplace**
3. Search for **Flutter Compile**
4. Click **Install** and restart the IDE

### From Disk (manual)

1. Download the `.zip` from the [Releases](https://github.com/flutterplaza/flutter_compile/releases) page
2. Open **Settings** > **Plugins** > gear icon > **Install Plugin from Disk...**
3. Select the `.zip` file and restart

## Features

### Tool Window

Open the **Flutter Compile** tool window from the bottom panel. It contains three tabs:

#### SDKs Tab

Browse, switch, pin, and remove Flutter SDKs from a tree view.

| Icon | Meaning |
|---|---|
| Green checkmark | Active SDK (global or project-pinned) |
| Package icon | Installed but inactive |
| Plugin icon | Locally compiled contributor build |

**Toolbar actions:**

- **Install SDK** (`+` button) — enter a version number or channel (e.g. `3.24.0`, `stable`, `beta`)
- **Refresh** — reload the SDK list from the CLI

**Right-click context menu:**

- **Set as Global** — make this SDK the global default
- **Pin to Project** — write a `.flutter-version` file in your project root so this project always uses this SDK
- **Open SDK Folder** — reveal the SDK directory in Finder / Explorer / Files
- **Remove SDK** — delete this SDK from disk (with confirmation dialog; disabled for contributor builds)

**Double-click** any SDK to set it as the global default.

#### Doctor Tab

Grouped diagnostic checks with pass/fail indicators.

- **Four categories:** Required Tools, Engine Tools, Configuration, Environments
- Each category header shows a summary count (e.g. `3/4 OK`)
- **Green check** = passing, **Red X** = failing/missing, **Yellow warning** = not configured or partial issue
- Details shown inline: install path, error message, or missing remotes
- Click **Refresh** to re-run all checks

#### Engine Builds Tab

At-a-glance engine status for contributors compiling the Flutter engine.

- **Engine path** — where the engine source lives on disk
- **Source status** — whether source files exist (green check or red X)
- **Host CPU** — detected architecture (e.g. `arm64`, `x86_64`)
- **Build targets** — each configured build with its name and disk size

When no engine is configured, the panel shows: "No engine configured. Run: flutter_compile engine init"

### Toolbar Combo Box

A combo box in the main toolbar shows the current global SDK version. Click to open a dropdown of all installed SDKs and switch instantly. The combo box text updates to reflect the active version.

### File Watcher

The plugin watches for changes to `.flutter-version` files in your project:

- Creating, editing, or deleting `.flutter-version` triggers an automatic refresh of the SDK tree
- External changes (e.g. running `flutter_compile sdk use` in a terminal) are picked up immediately

### CLI Availability Check

On project open, the plugin checks if `flutter_compile` is available. If not found, a warning notification balloon appears with an **Install Instructions** link.

### Automatic SDK Path Updates

When you switch SDKs (set global, pin to project, or select from the combo box), the plugin updates the Flutter SDK path in IntelliJ's project settings via the Flutter plugin API. The Dart analysis server picks up the change immediately.

## Menu Actions

All actions are also available from the **Tools** menu:

| Menu Item | Description |
|---|---|
| Install Flutter SDK... | Install a new SDK version or channel |
| Flutter Compile Doctor | Run diagnostics and show the tool window |
| Remove Flutter SDK... | Choose and remove an installed SDK |
| Pin Flutter SDK to Project... | Choose and pin an SDK to the current project |
| Open Flutter SDK Folder... | Choose and reveal an SDK directory in the file manager |
| Refresh Flutter Compile | Refresh all three panels |

## Settings

Go to **Settings** > **Tools** > **Flutter Compile**:

| Setting | Default | Description |
|---|---|---|
| CLI Path | `flutter_compile` | Path to the `flutter_compile` CLI executable. Change this if the CLI is not on your `PATH`. |

## How It Works

The plugin calls the `flutter_compile` CLI under the hood:

| CLI command | Plugin feature |
|---|---|
| `sdk list --json` | SDK tree view, toolbar combo box |
| `config get global_sdk` | Toolbar combo box text |
| `sdk global <version>` | Set as Global |
| `sdk use <version>` | Pin to Project |
| `sdk install <version>` | Install SDK |
| `sdk remove <version>` | Remove SDK |
| `doctor --json` | Doctor tree view |
| `status --json` | Engine Builds view |
| `--version` | CLI availability check on startup |

All CLI commands use a 120-second timeout (10 seconds for `--version`).

## Troubleshooting

| Problem | Solution |
|---|---|
| "flutter_compile CLI not found" balloon | Install the CLI: `dart pub global activate flutter_compile`. Make sure `~/.pub-cache/bin` is in your `PATH`. |
| SDK tree is empty | Click the Refresh button. If still empty, run `flutter_compile sdk list` in a terminal to check if SDKs are installed. |
| Doctor shows all red | The CLI may not be configured. Run `flutter_compile doctor` in a terminal to see detailed output. |
| Toolbar combo shows "(none)" | No global SDK is set. Use **Set as Global** from the SDK tree's right-click menu. |
| SDK switch doesn't take effect | Restart the Dart analysis server: **File** > **Invalidate Caches / Restart**, or close and reopen the project. |
| Plugin not visible | Make sure the Dart and Flutter plugins are installed and enabled. The Flutter Compile plugin depends on both. |

## Building from Source

```sh
cd extensions/intellij
./gradlew build     # compile and package
./gradlew runIde    # launch a sandbox IDE with the plugin loaded
```

Requires JDK 17+ and Gradle 8.13+.

## License

BSD-3-Clause. See [LICENSE](https://github.com/flutterplaza/flutter_compile/blob/main/extensions/intellij/LICENSE).
