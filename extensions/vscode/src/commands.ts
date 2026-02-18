import * as vscode from "vscode";
import * as cli from "./cli";
import * as statusBar from "./statusBar";
import { updateFlutterSdkPath } from "./sdkSettings";

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
    return {
      label: sdk.version,
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

  const version = picked.label;

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: `Switching to Flutter SDK ${version}...`,
    },
    async () => {
      try {
        await cli.setGlobalSdk(version);
        await updateFlutterSdkPath(version);
        await statusBar.refresh();
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
