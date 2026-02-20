import * as vscode from "vscode";
import * as cli from "./cli";
import * as statusBar from "./statusBar";
import { updateFlutterSdkPath } from "./sdkSettings";
import type { SdkTreeItem } from "./views/sdkTreeProvider";

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
  cli.installSdk(version);
}

/**
 * `Flutter Compile: Switch SDK` / `Flutter Compile: Select SDK`
 *
 * Shows a quick pick of installed SDKs. Selecting one sets it as global,
 * updates `dart.flutterSdkPath`, and refreshes the status bar.
 */
export async function selectSdk(): Promise<void> {
  const sdks = await cli.listSdks();
  if (sdks.length === 0) {
    const action = await vscode.window.showInformationMessage(
      "No Flutter SDKs installed via flutter_compile.",
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
        await cli.setGlobalSdk(version);
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

  const sdks = await cli.listSdks();
  if (sdks.length === 0) {
    vscode.window.showInformationMessage(
      "No Flutter SDKs installed via flutter_compile."
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
        await cli.removeSdk(version);
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
        await cli.setGlobalSdk(version);
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

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Pinning Flutter SDK ${version} to project...`,
    },
    async () => {
      try {
        await cli.useSdk(version);
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

  const sdkPath = await cli.getSdkPath(version);
  if (!sdkPath) {
    vscode.window.showErrorMessage(
      `Could not find path for SDK ${version}.`
    );
    return;
  }

  const uri = vscode.Uri.file(sdkPath);
  await vscode.commands.executeCommand("revealFileInOS", uri);
}
