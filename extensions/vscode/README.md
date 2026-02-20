# Flutter Compile — VS Code Extension

Manage multiple Flutter SDK versions, run diagnostics, and monitor engine builds — all from the VS Code sidebar. No terminal needed.

## Prerequisites

| Requirement | How to install |
|---|---|
| **flutter_compile CLI** | `dart pub global activate flutter_compile` |
| VS Code **1.85.0** or later | [code.visualstudio.com](https://code.visualstudio.com/) |

> The CLI must be on your `PATH`. Run `flutter_compile --version` to verify.
> If you open a project without the CLI installed, the extension will show a warning notification with a link to installation instructions.

## Installation

1. Open VS Code
2. Go to **Extensions** (`Cmd+Shift+X` / `Ctrl+Shift+X`)
3. Search for **Flutter Compile**
4. Click **Install**

Or install from the command line:

```sh
code --install-extension flutterPlaza-com.flutter-compile
```

## Features

### SDK Manager (Sidebar)

The **SDKs** view in the Flutter Compile sidebar lets you browse, switch, pin, and remove Flutter SDKs.

| Icon | Meaning |
|---|---|
| Green checkmark | Active SDK (global or project-pinned) |
| Package icon | Installed but inactive |
| Beaker icon | Locally compiled contributor build |

**Available actions:**

- **Install SDK** — click the `+` button in the view header, then enter a version number or channel (e.g. `3.24.0`, `stable`, `beta`)
- **Set Global** — inline button on each SDK row, or right-click > Set Global SDK
- **Pin to Project** — right-click > Pin SDK to Project (writes a `.flutter-version` file in your project root)
- **Open SDK Folder** — right-click > Open SDK Folder (reveals the SDK directory in Finder / Explorer)
- **Remove SDK** — inline trash button, or right-click > Remove SDK (with confirmation dialog)
- **Refresh** — click the refresh button in the view header

Double descriptions appear next to each SDK entry: `global`, `project`, or both.

### Doctor

The **Doctor** view shows grouped diagnostic checks with pass/fail indicators — no need to read terminal output.

- **Four categories:** Required Tools, Engine Tools, Configuration, Environments
- Each category header shows a summary (e.g. `3/4 OK`)
- **Green check** = passing, **Red X** = failing/missing, **Yellow warning** = not configured or partial
- Hover over any check for detailed tooltip (path, error message, missing remotes)
- Click **Refresh** in the view header to re-run all checks

### Engine Builds

The **Engine Builds** view gives contributors an at-a-glance view of their local Flutter engine.

- **Engine path** — where the engine source lives on disk
- **Source status** — whether source files exist (green check or red X)
- **Host CPU** — detected architecture (e.g. `arm64`, `x86_64`)
- **Build targets** — each configured build with its name and disk size

When no engine is configured, the view shows a welcome message with setup instructions.

### Status Bar

An always-visible indicator in the bottom status bar:

- Shows the current global or project-pinned SDK version
- **Yellow warning background** when no SDK is set
- Click it to open the SDK quick picker

### File Watcher

The extension watches for changes to `.flutter-version` files in your workspace:

- Creating, editing, or deleting `.flutter-version` triggers an automatic refresh of the SDK tree and status bar
- This means external tools (like `flutter_compile sdk use` in a terminal) are picked up immediately

### Automatic SDK Path Updates

When you switch SDKs (set global, pin to project, or select from the quick picker), the extension automatically updates `dart.flutterSdkPath` in your workspace settings. The Dart/Flutter VS Code extensions pick up the change immediately — no restart needed.

## Commands

All commands are available via the Command Palette (`Cmd+Shift+P` / `Ctrl+Shift+P`):

| Command | Description |
|---|---|
| `Flutter Compile: Install SDK` | Install a new Flutter SDK version or channel |
| `Flutter Compile: Select SDK` | Pick from installed SDKs with a quick picker |
| `Flutter Compile: Switch SDK` | Alias for Select SDK |
| `Flutter Compile: Set Global SDK` | Set an SDK as the global default |
| `Flutter Compile: Pin SDK to Project` | Write `.flutter-version` for the current workspace |
| `Flutter Compile: Remove SDK` | Delete an installed SDK from disk |
| `Flutter Compile: Open SDK Folder` | Reveal an SDK directory in the system file manager |
| `Flutter Compile: Doctor` | Run diagnostics and print raw output to the output channel |
| `Flutter Compile: Refresh SDKs` | Refresh the SDK tree view |
| `Flutter Compile: Refresh Doctor` | Re-run doctor checks |
| `Flutter Compile: Refresh Builds` | Refresh engine build status |
| `Flutter Compile: Refresh All` | Refresh all three views and the status bar |

## Extension Settings

Configure via **Settings** (`Cmd+,` / `Ctrl+,`) or `.vscode/settings.json`:

| Setting | Type | Default | Description |
|---|---|---|---|
| `flutterCompile.cliPath` | `string` | `"flutter_compile"` | Path to the `flutter_compile` CLI executable. Change this if the CLI is not on your `PATH`. |

## How It Works

The extension calls the `flutter_compile` CLI under the hood:

| CLI command | Extension feature |
|---|---|
| `sdk list --json` | SDK tree view |
| `config get global_sdk` | Status bar, quick picker |
| `sdk global <version>` | Set Global SDK |
| `sdk use <version>` | Pin to Project |
| `sdk install <version>` | Install SDK (runs in terminal) |
| `sdk remove <version>` | Remove SDK |
| `doctor --json` | Doctor tree view |
| `status --json` | Engine Builds view |
| `--version` | CLI availability check |

All JSON-based commands use a 120-second timeout.

## Troubleshooting

| Problem | Solution |
|---|---|
| "flutter_compile CLI not found" notification | Install the CLI: `dart pub global activate flutter_compile`. Make sure `~/.pub-cache/bin` is in your `PATH`. |
| SDK tree is empty | Click the refresh button. If still empty, run `flutter_compile sdk list` in a terminal to verify SDKs are installed. |
| Doctor shows all red | The CLI may not be configured. Run `flutter_compile doctor` in a terminal to see detailed output. |
| Status bar shows "(none)" with yellow background | No global or project SDK is set. Use **Set Global SDK** or **Pin SDK to Project** to fix this. |
| SDK switch doesn't take effect in Dart extension | Restart the Dart analysis server: Command Palette > `Dart: Restart Analysis Server`. |

## License

BSD-3-Clause. See [LICENSE](https://github.com/flutterplaza/flutter_compile/blob/main/extensions/vscode/LICENSE).
