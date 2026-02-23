import * as vscode from "vscode";
import * as statusBar from "./statusBar";
import * as commands from "./commands";
import * as versionWatcher from "./versionWatcher";
import * as cli from "./cli";
import { reloadBackend, getMode } from "./sdkProvider";
import { SdkTreeProvider } from "./views/sdkTreeProvider";
import { DoctorTreeProvider } from "./views/doctorTreeProvider";
import { BuildsTreeProvider } from "./views/buildsTreeProvider";

export async function activate(
  context: vscode.ExtensionContext
): Promise<void> {
  // Soft check for CLI availability (info-level, not blocking)
  const available = await cli.isCliAvailable();
  if (!available) {
    vscode.window.showInformationMessage(
      "flutter_compile CLI not found. SDK management uses the built-in backend. " +
        "Install the CLI for doctor/engine features.",
    );
  }

  // Status bar — shows active Flutter SDK version
  const item = statusBar.create();
  context.subscriptions.push(item);
  statusBar.refresh();

  // Tree view providers
  const sdkProvider = new SdkTreeProvider();
  const doctorProvider = new DoctorTreeProvider();
  const buildsProvider = new BuildsTreeProvider();

  const sdkTreeView = vscode.window.createTreeView("flutterCompile.sdks", {
    treeDataProvider: sdkProvider,
  });
  sdkTreeView.description = getMode() === "fvm" ? "FVM" : "Native";

  context.subscriptions.push(
    sdkTreeView,
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
    }),
    vscode.commands.registerCommand(
      "flutterCompile.initEngine",
      commands.initEngine
    ),
    vscode.commands.registerCommand(
      "flutterCompile.buildEngine",
      commands.buildEngine
    ),
    vscode.commands.registerCommand(
      "flutterCompile.deleteBuild",
      commands.deleteBuild
    ),
    vscode.commands.registerCommand(
      "flutterCompile.installDoctorCheck",
      commands.installDoctorCheck
    ),
    vscode.commands.registerCommand(
      "flutterCompile.uninstallEnvironment",
      commands.uninstallDoctorEnvironment
    ),
    vscode.commands.registerCommand(
      "flutterCompile.toggleSdkManager",
      commands.toggleSdkManager
    )
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

  // Listen for sdkManager setting changes and reload the backend
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("flutterCompile.sdkManager")) {
        reloadBackend();
        // Restart watchers for the new mode
        versionWatcher.stop();
        const newDisposables = versionWatcher.start(() => {
          sdkProvider.refresh();
        });
        context.subscriptions.push(...newDisposables);
        // Refresh everything with the new backend
        sdkTreeView.description = getMode() === "fvm" ? "FVM" : "Native";
        sdkProvider.refresh();
        statusBar.refresh();
      }
    })
  );
}

export function deactivate(): void {
  statusBar.dispose();
  versionWatcher.stop();
}
