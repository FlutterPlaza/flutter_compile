import * as vscode from "vscode";
import * as cli from "./cli";

let statusBarItem: vscode.StatusBarItem;

/** Create and show the status bar item. */
export function create(): vscode.StatusBarItem {
  statusBarItem = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Left,
    50
  );
  statusBarItem.command = "flutterCompile.selectSdk";
  statusBarItem.tooltip = "Flutter Compile — click to switch SDK";
  statusBarItem.text = "$(versions) Flutter SDK: ...";
  statusBarItem.show();
  return statusBarItem;
}

/** Refresh the status bar text with the current SDK version. */
export async function refresh(): Promise<void> {
  if (!statusBarItem) {
    return;
  }

  // Check for project-level .flutter-version first
  const projectVersion = await readProjectVersion();
  if (projectVersion) {
    statusBarItem.text = `$(versions) Flutter SDK: ${projectVersion} (project)`;
    statusBarItem.backgroundColor = undefined;
    return;
  }

  // Fall back to global
  const globalVersion = await cli.getGlobalSdkVersion();
  if (globalVersion) {
    statusBarItem.text = `$(versions) Flutter SDK: ${globalVersion}`;
    statusBarItem.backgroundColor = undefined;
  } else {
    statusBarItem.text = "$(versions) Flutter SDK: (none)";
    statusBarItem.backgroundColor = new vscode.ThemeColor(
      "statusBarItem.warningBackground"
    );
  }
}

/** Read .flutter-version from the first workspace folder. */
async function readProjectVersion(): Promise<string | undefined> {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return undefined;
  }
  const uri = vscode.Uri.joinPath(folders[0].uri, ".flutter-version");
  try {
    const bytes = await vscode.workspace.fs.readFile(uri);
    const content = Buffer.from(bytes).toString("utf-8").trim();
    return content || undefined;
  } catch {
    return undefined;
  }
}

/** Dispose the status bar item. */
export function dispose(): void {
  statusBarItem?.dispose();
}
