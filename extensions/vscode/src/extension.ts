import * as vscode from "vscode";
import * as statusBar from "./statusBar";
import * as commands from "./commands";
import * as versionWatcher from "./versionWatcher";

export function activate(context: vscode.ExtensionContext): void {
  // Status bar — shows active Flutter SDK version
  const item = statusBar.create();
  context.subscriptions.push(item);

  // Refresh status bar on activation
  statusBar.refresh();

  // Register commands
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "flutterCompile.installSdk",
      commands.installSdk
    ),
    vscode.commands.registerCommand(
      "flutterCompile.switchSdk",
      commands.selectSdk
    ),
    vscode.commands.registerCommand(
      "flutterCompile.selectSdk",
      commands.selectSdk
    ),
    vscode.commands.registerCommand(
      "flutterCompile.doctor",
      commands.doctor
    )
  );

  // Watch .flutter-version for external changes
  const watcherDisposables = versionWatcher.start();
  context.subscriptions.push(...watcherDisposables);

  // Refresh when workspace folders change
  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(() => {
      statusBar.refresh();
    })
  );
}

export function deactivate(): void {
  statusBar.dispose();
  versionWatcher.stop();
}
