import * as vscode from "vscode";
import * as statusBar from "./statusBar";
import * as commands from "./commands";
import * as versionWatcher from "./versionWatcher";
import * as cli from "./cli";
import { SdkTreeProvider } from "./views/sdkTreeProvider";
import { DoctorTreeProvider } from "./views/doctorTreeProvider";
import { BuildsTreeProvider } from "./views/buildsTreeProvider";

export async function activate(
  context: vscode.ExtensionContext
): Promise<void> {
  // Check CLI availability
  const available = await cli.isCliAvailable();
  if (!available) {
    const action = await vscode.window.showWarningMessage(
      "flutter_compile CLI not found. Install it to use this extension.",
      "Show Install Instructions"
    );
    if (action === "Show Install Instructions") {
      vscode.env.openExternal(
        vscode.Uri.parse(
          "https://github.com/flutterplaza/flutter_compile#installation"
        )
      );
    }
  }

  // Status bar — shows active Flutter SDK version
  const item = statusBar.create();
  context.subscriptions.push(item);
  statusBar.refresh();

  // Tree view providers
  const sdkProvider = new SdkTreeProvider();
  const doctorProvider = new DoctorTreeProvider();
  const buildsProvider = new BuildsTreeProvider();

  context.subscriptions.push(
    vscode.window.createTreeView("flutterCompile.sdks", {
      treeDataProvider: sdkProvider,
    }),
    vscode.window.createTreeView("flutterCompile.doctor", {
      treeDataProvider: doctorProvider,
    }),
    vscode.window.createTreeView("flutterCompile.builds", {
      treeDataProvider: buildsProvider,
    })
  );

  // Wire refresh callback so mutating commands refresh tree views
  commands.setRefreshCallback(() => {
    sdkProvider.refresh();
    doctorProvider.refresh();
    buildsProvider.refresh();
  });

  // Register existing commands
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

  // Register new commands
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "flutterCompile.removeSdk",
      commands.removeSdk
    ),
    vscode.commands.registerCommand(
      "flutterCompile.setGlobalSdk",
      commands.setGlobalSdk
    ),
    vscode.commands.registerCommand(
      "flutterCompile.pinSdkToProject",
      commands.pinSdkToProject
    ),
    vscode.commands.registerCommand(
      "flutterCompile.openSdkFolder",
      commands.openSdkFolder
    ),
    vscode.commands.registerCommand("flutterCompile.refreshSdks", () => {
      sdkProvider.refresh();
    }),
    vscode.commands.registerCommand(
      "flutterCompile.refreshDoctor",
      () => {
        doctorProvider.refresh();
      }
    ),
    vscode.commands.registerCommand(
      "flutterCompile.refreshBuilds",
      () => {
        buildsProvider.refresh();
      }
    ),
    vscode.commands.registerCommand("flutterCompile.refreshAll", () => {
      sdkProvider.refresh();
      doctorProvider.refresh();
      buildsProvider.refresh();
      statusBar.refresh();
    })
  );

  // Watch .flutter-version for external changes
  const watcherDisposables = versionWatcher.start(() => {
    sdkProvider.refresh();
  });
  context.subscriptions.push(...watcherDisposables);

  // Refresh when workspace folders change
  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(() => {
      statusBar.refresh();
      sdkProvider.refresh();
    })
  );
}

export function deactivate(): void {
  statusBar.dispose();
  versionWatcher.stop();
}
