import * as vscode from "vscode";
import * as cli from "./cli";
import { getBackend, getMode } from "./sdkProvider";
import * as statusBar from "./statusBar";
import { updateFlutterSdkPath } from "./sdkSettings";
import type { SdkTreeItem } from "./views/sdkTreeProvider";
import type { BuildEntryItem } from "./views/buildsTreeProvider";
import type { CheckItem } from "./views/doctorTreeProvider";

/** Callback invoked after mutating commands to refresh tree views. */
export type RefreshCallback = () => void;

let _onRefresh: RefreshCallback | undefined;

/** Set the callback that gets invoked after SDK mutations. */
export function setRefreshCallback(cb: RefreshCallback): void {
  _onRefresh = cb;
}

/** Trigger refresh of tree views and status bar after mutations. */
async function refreshAll(): Promise<void> {
  await statusBar.refresh();
  _onRefresh?.();
}

/** `Flutter Compile: Install SDK` — prompt for version, then install. */
export async function installSdk(): Promise<void> {
  const version = await vscode.window.showInputBox({
    prompt: "Enter Flutter SDK version or channel to install",
    placeHolder: "e.g. 3.24.0, stable, beta",
  });
  if (!version) {
    return;
  }
  getBackend().installSdkInTerminal(version);
}

/**
 * `Flutter Compile: Switch SDK` / `Flutter Compile: Select SDK`
 *
 * Shows a quick pick of installed SDKs. Selecting one sets it as global,
 * updates `dart.flutterSdkPath`, and refreshes the status bar.
 */
export async function selectSdk(): Promise<void> {
  const backend = getBackend();
  const sdks = await backend.listSdks();
  if (sdks.length === 0) {
    const action = await vscode.window.showInformationMessage(
      "No Flutter SDKs installed.",
      "Install SDK"
    );
    if (action === "Install SDK") {
      await installSdk();
    }
    return;
  }

  const items: vscode.QuickPickItem[] = sdks.map((sdk) => {
    const markers: string[] = [];
    if (sdk.global) {
      markers.push("global");
    }
    if (sdk.project) {
      markers.push("project");
    }
    const desc = markers.length > 0 ? `(${markers.join(", ")})` : "";

    let icon = "$(package)";
    if (sdk.contributor) {
      icon = "$(beaker)";
    } else if (sdk.global || sdk.project) {
      icon = "$(check)";
    }

    return {
      label: `${icon} ${sdk.version}`,
      description: desc,
      detail: sdk.path,
    };
  });

  const picked = await vscode.window.showQuickPick(items, {
    placeHolder: "Select a Flutter SDK version",
  });
  if (!picked) {
    return;
  }

  // Strip icon prefix to get version
  const version = picked.label.replace(/^\$\([^)]+\)\s*/, "");

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Switching to Flutter SDK ${version}...`,
    },
    async () => {
      try {
        await backend.setGlobalSdk(version);
        await updateFlutterSdkPath(version);
        await refreshAll();
        vscode.window.showInformationMessage(
          `Switched to Flutter SDK ${version}.`
        );
      } catch (e) {
        vscode.window.showErrorMessage(
          `Failed to switch SDK: ${e}`
        );
      }
    }
  );
}

/** `Flutter Compile: Doctor` — run doctor and show output. */
export async function doctor(): Promise<void> {
  const output = await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Running flutter_compile doctor...",
    },
    async () => {
      return await cli.runDoctor();
    }
  );

  const channel = vscode.window.createOutputChannel("Flutter Compile");
  channel.clear();
  channel.appendLine(output);
  channel.show();
}

/** Pick an SDK version from quick pick, or use tree item if provided. */
async function pickSdkVersion(
  item?: SdkTreeItem
): Promise<string | undefined> {
  if (item) {
    return item.sdk.version;
  }

  const sdks = await getBackend().listSdks();
  if (sdks.length === 0) {
    vscode.window.showInformationMessage(
      "No Flutter SDKs installed."
    );
    return undefined;
  }

  const picked = await vscode.window.showQuickPick(
    sdks.map((s) => s.version),
    { placeHolder: "Select a Flutter SDK version" }
  );
  return picked;
}

/** Remove an SDK. */
export async function removeSdk(item?: SdkTreeItem): Promise<void> {
  const version = await pickSdkVersion(item);
  if (!version) {
    return;
  }

  const confirm = await vscode.window.showWarningMessage(
    `Remove Flutter SDK ${version}? This cannot be undone.`,
    { modal: true },
    "Remove"
  );
  if (confirm !== "Remove") {
    return;
  }

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Removing Flutter SDK ${version}...`,
    },
    async () => {
      try {
        await getBackend().removeSdk(version);
        await refreshAll();
        vscode.window.showInformationMessage(
          `Removed Flutter SDK ${version}.`
        );
      } catch (e) {
        vscode.window.showErrorMessage(
          `Failed to remove SDK: ${e}`
        );
      }
    }
  );
}

/** Set an SDK as the global default. */
export async function setGlobalSdk(item?: SdkTreeItem): Promise<void> {
  const version = await pickSdkVersion(item);
  if (!version) {
    return;
  }

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Setting Flutter SDK ${version} as global...`,
    },
    async () => {
      try {
        await getBackend().setGlobalSdk(version);
        await updateFlutterSdkPath(version);
        await refreshAll();
        vscode.window.showInformationMessage(
          `Set Flutter SDK ${version} as global.`
        );
      } catch (e) {
        vscode.window.showErrorMessage(
          `Failed to set global SDK: ${e}`
        );
      }
    }
  );
}

/** Pin an SDK to the current project via `.flutter-version`. */
export async function pinSdkToProject(
  item?: SdkTreeItem
): Promise<void> {
  const version = await pickSdkVersion(item);
  if (!version) {
    return;
  }

  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    vscode.window.showErrorMessage("No workspace folder open.");
    return;
  }
  const projectRoot = folders[0].uri.fsPath;

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Pinning Flutter SDK ${version} to project...`,
    },
    async () => {
      try {
        await getBackend().pinToProject(version, projectRoot);
        await updateFlutterSdkPath(version);
        await refreshAll();
        vscode.window.showInformationMessage(
          `Pinned Flutter SDK ${version} to project.`
        );
      } catch (e) {
        vscode.window.showErrorMessage(
          `Failed to pin SDK: ${e}`
        );
      }
    }
  );
}

/** Open the SDK folder in the OS file explorer. */
export async function openSdkFolder(item?: SdkTreeItem): Promise<void> {
  const version = await pickSdkVersion(item);
  if (!version) {
    return;
  }

  const sdkPath = await getBackend().getSdkPath(version);
  if (!sdkPath) {
    vscode.window.showErrorMessage(
      `Could not find path for SDK ${version}.`
    );
    return;
  }

  const uri = vscode.Uri.file(sdkPath);
  await vscode.commands.executeCommand("revealFileInOS", uri);
}

// ─── Engine commands ──────────────────────────────────────────────────

/** Initialize the Flutter engine environment in a terminal. */
export function initEngine(): void {
  cli.runInTerminal(["install", "engine"]);
}

/** Build the Flutter engine with user-selected options. */
export async function buildEngine(): Promise<void> {
  const platform = await vscode.window.showQuickPick(
    ["host", "android", "ios", "macos", "linux", "web"],
    { placeHolder: "Select target platform" }
  );
  if (!platform) {
    return;
  }

  const mode = await vscode.window.showQuickPick(
    ["debug", "profile", "release"],
    { placeHolder: "Select build mode" }
  );
  if (!mode) {
    return;
  }

  const flags = await vscode.window.showQuickPick(
    [
      { label: "Unoptimized", description: "Faster dev builds", picked: true },
      { label: "Clean", description: "Clean output before building", picked: false },
      { label: "Force GN", description: "Force re-running GN", picked: false },
    ],
    { placeHolder: "Select build flags", canPickMany: true }
  );
  if (!flags) {
    return;
  }

  const args = ["build", "engine", "-p", platform, "-m", mode];
  const flagLabels = new Set(flags.map((f) => f.label));
  if (flagLabels.has("Unoptimized")) {
    args.push("--unoptimized");
  } else {
    args.push("--no-unoptimized");
  }
  if (flagLabels.has("Clean")) {
    args.push("--clean");
  }
  if (flagLabels.has("Force GN")) {
    args.push("--gn");
  }

  cli.runInTerminal(args);
}

/** Delete a specific engine build output. */
export async function deleteBuild(item?: BuildEntryItem): Promise<void> {
  if (!item) {
    return;
  }

  const confirm = await vscode.window.showWarningMessage(
    `Delete engine build "${item.buildName}" (${item.buildSize})? This cannot be undone.`,
    { modal: true },
    "Delete"
  );
  if (confirm !== "Delete") {
    return;
  }

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Deleting build ${item.buildName}...`,
    },
    async () => {
      try {
        await cli.cleanBuild(item.buildName);
        await refreshAll();
        vscode.window.showInformationMessage(
          `Deleted build "${item.buildName}".`
        );
      } catch (e) {
        vscode.window.showErrorMessage(
          `Failed to delete build: ${e}`
        );
      }
    }
  );
}

// ─── Doctor install/configure actions ────────────────────────────────

/** Install or configure a failing doctor check. */
export async function installDoctorCheck(item?: CheckItem): Promise<void> {
  if (!item) {
    return;
  }

  const check = item.check;
  if (check.status === "ok") {
    return;
  }

  const name = check.name.toLowerCase();

  // Map check names to install actions
  if (name === "ninja") {
    runInstallInTerminal("brew install ninja", "Installing ninja...");
  } else if (name === "xcode" || name === "xcode command line tools") {
    runInstallInTerminal("xcode-select --install", "Installing Xcode CLI tools...");
  } else if (name === "gclient") {
    const home = process.env.HOME ?? process.env.USERPROFILE ?? "~";
    const depotPath = `${home}/flutter_compile/depot_tools`;
    const shellRc = process.env.SHELL?.includes("zsh") ? ".zshrc" : ".bashrc";
    const marker = "Added by flutter_compile setup CLI (depot_tools)";
    const pathExport = `\\n# >>> ${marker} >>>\\nexport PATH=${depotPath}:\\$PATH\\n# <<< ${marker} <<<\\n`;
    // Clone only if not already present; then ensure PATH is in shell config
    const cloneCmd = `if [ ! -d "${depotPath}" ]; then mkdir -p "$(dirname "${depotPath}")" && git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${depotPath}"; else echo "depot_tools already installed at ${depotPath}"; fi`;
    const pathCmd = `if ! grep -q "${marker}" ~/${shellRc} 2>/dev/null; then echo -e '${pathExport}' >> ~/${shellRc} && echo "Added depot_tools to PATH in ~/${shellRc}."; else echo "PATH already configured in ~/${shellRc}."; fi`;
    runInstallInTerminal(
      `${cloneCmd} && ${pathCmd} && echo "Done. Restart your terminal to apply PATH changes."`,
      "Installing depot_tools..."
    );
  } else if (name === "python3" || name === "python") {
    vscode.env.openExternal(vscode.Uri.parse("https://www.python.org/downloads/"));
  } else if (name === "git") {
    vscode.env.openExternal(vscode.Uri.parse("https://git-scm.com/downloads"));
  } else if (name === ".flutter_compilerc") {
    const os = process.platform;
    const home = os === "win32" ? process.env.USERPROFILE : process.env.HOME;
    if (home) {
      const fs = await import("fs");
      const path = `${home}/.flutter_compilerc`;
      if (!fs.existsSync(path)) {
        fs.writeFileSync(path, "");
        vscode.window.showInformationMessage("Created ~/.flutter_compilerc");
        await refreshAll();
      }
    }
  } else if (
    name.includes("flutter contributor") ||
    name.includes("flutter") && check.category === "environments"
  ) {
    cli.runInTerminal(["install", "flutter", "--ide", "vscode"]);
  } else if (
    name.includes("devtools contributor") ||
    name.includes("devtools") && check.category === "environments"
  ) {
    cli.runInTerminal(["install", "devtools"]);
  } else if (
    name.includes("engine contributor") ||
    name.includes("engine") && check.category === "environments"
  ) {
    cli.runInTerminal(["install", "engine"]);
  } else {
    vscode.window.showInformationMessage(
      `No automatic install available for "${check.name}". Check the flutter_compile documentation.`
    );
  }
}

/** Uninstall a contributor environment (OK env items). */
export async function uninstallDoctorEnvironment(item?: CheckItem): Promise<void> {
  if (!item) {
    return;
  }

  const check = item.check;
  if (check.category !== "environments") {
    return;
  }

  const name = check.name.toLowerCase();
  let type: "flutter" | "devtools" | "engine";
  if (name.includes("flutter")) {
    type = "flutter";
  } else if (name.includes("devtools")) {
    type = "devtools";
  } else if (name.includes("engine")) {
    type = "engine";
  } else {
    vscode.window.showInformationMessage(
      `No uninstall action available for "${check.name}".`
    );
    return;
  }

  const confirm = await vscode.window.showWarningMessage(
    `Uninstall ${type} contributor environment? This cannot be undone.`,
    { modal: true },
    "Uninstall"
  );
  if (confirm !== "Uninstall") {
    return;
  }

  cli.uninstallEnvironment(type);
}

/** `Flutter Compile: Switch SDK Manager` — toggle between Native and FVM backends. */
export async function toggleSdkManager(): Promise<void> {
  const current = getMode();
  const items = [
    { label: "Native", value: "native" as const },
    { label: "FVM", value: "fvm" as const },
  ];
  const picked = await vscode.window.showQuickPick(items, {
    placeHolder: `Current: ${current === "fvm" ? "FVM" : "Native"}`,
  });
  if (!picked || picked.value === current) {
    return;
  }
  await vscode.workspace
    .getConfiguration("flutterCompile")
    .update("sdkManager", picked.value, vscode.ConfigurationTarget.Global);
}

function runInstallInTerminal(command: string, title: string): void {
  const terminal = vscode.window.createTerminal(title);
  terminal.sendText(command);
  terminal.show();
}
