import * as vscode from "vscode";
import * as statusBar from "./statusBar";
import { updateFlutterSdkPath } from "./sdkSettings";

let watcher: vscode.FileSystemWatcher | undefined;

/** Start watching `.flutter-version` in all workspace folders. */
export function start(): vscode.Disposable[] {
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
      }
    } catch {
      // File may have been deleted — refresh will handle "(none)"
      await statusBar.refresh();
    }
  };

  watcher.onDidChange(onChange);
  watcher.onDidCreate(onChange);
  watcher.onDidDelete(async () => {
    await statusBar.refresh();
  });

  disposables.push(watcher);
  return disposables;
}

/** Stop the file watcher. */
export function stop(): void {
  watcher?.dispose();
  watcher = undefined;
}
