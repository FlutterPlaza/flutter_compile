import * as vscode from "vscode";
import * as statusBar from "./statusBar";
import { updateFlutterSdkPath } from "./sdkSettings";
import { getMode } from "./sdkProvider";

let watcher: vscode.FileSystemWatcher | undefined;
let fvmrcWatcher: vscode.FileSystemWatcher | undefined;

/** Start watching `.flutter-version` (and `.fvmrc` in FVM mode) in all workspace folders. */
export function start(
  onSdkChanged?: () => void
): vscode.Disposable[] {
  const disposables: vscode.Disposable[] = [];

  watcher = vscode.workspace.createFileSystemWatcher(
    "**/.flutter-version"
  );

  const onChange = async (uri: vscode.Uri) => {
    try {
      const bytes = await vscode.workspace.fs.readFile(uri);
      const version = Buffer.from(bytes).toString("utf-8").trim();
      if (version) {
        await statusBar.refresh();
        await updateFlutterSdkPath(version);
        onSdkChanged?.();
      }
    } catch {
      // File may have been deleted — refresh will handle "(none)"
      await statusBar.refresh();
      onSdkChanged?.();
    }
  };

  watcher.onDidChange(onChange);
  watcher.onDidCreate(onChange);
  watcher.onDidDelete(async () => {
    await statusBar.refresh();
    onSdkChanged?.();
  });

  disposables.push(watcher);

  // Also watch .fvmrc when in FVM mode
  if (getMode() === "fvm") {
    fvmrcWatcher = vscode.workspace.createFileSystemWatcher("**/.fvmrc");

    const onFvmrcChange = async () => {
      await statusBar.refresh();
      onSdkChanged?.();
    };

    fvmrcWatcher.onDidChange(onFvmrcChange);
    fvmrcWatcher.onDidCreate(onFvmrcChange);
    fvmrcWatcher.onDidDelete(onFvmrcChange);

    disposables.push(fvmrcWatcher);
  }

  return disposables;
}

/** Stop all file watchers. */
export function stop(): void {
  watcher?.dispose();
  watcher = undefined;
  fvmrcWatcher?.dispose();
  fvmrcWatcher = undefined;
}
