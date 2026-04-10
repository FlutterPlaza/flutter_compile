import * as vscode from "vscode";
import * as path from "path";
import * as statusBar from "./statusBar";
import * as commands from "./commands";
import * as versionWatcher from "./versionWatcher";
import * as cli from "./cli";
import { reloadBackend, getMode, getBackend } from "./sdkProvider";
import { migrateEnvFile } from "./nativeSdkBackend";
import { SdkTreeProvider } from "./views/sdkTreeProvider";
import { DoctorTreeProvider } from "./views/doctorTreeProvider";
import { BuildsTreeProvider } from "./views/buildsTreeProvider";
import { CodePushTreeProvider } from "./views/codePushTreeProvider";

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
  const codePushProvider = new CodePushTreeProvider();

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

  context.subscriptions.push(
    vscode.window.createTreeView("flutterCompile.codePush", {
      treeDataProvider: codePushProvider,
    })
  );

  // Wire refresh callback so mutating commands refresh tree views
  commands.setRefreshCallback(() => {
    sdkProvider.refresh();
    doctorProvider.refresh();
    buildsProvider.refresh();
    codePushProvider.refresh();
    updateTerminalEnv(context);
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
      "flutterCompile.unpinSdkFromProject",
      commands.unpinSdkFromProject
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
      codePushProvider.refresh();
      statusBar.refresh();
      updateTerminalEnv(context);
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

  // Register code push commands
  context.subscriptions.push(
    vscode.commands.registerCommand(
      "flutterCompile.codePushLogin",
      commands.codePushLogin
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushInit",
      commands.codePushInit
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushRelease",
      commands.codePushRelease
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushPatch",
      commands.codePushPatch
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushRollback",
      commands.codePushRollback
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushDownloadVersion",
      commands.codePushDownloadVersion
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushSetVersion",
      commands.codePushSetVersion
    ),
    vscode.commands.registerCommand(
      "flutterCompile.codePushCopyPatchId",
      commands.codePushCopyPatchId
    ),
    vscode.commands.registerCommand("flutterCompile.refreshCodePush", () => {
      codePushProvider.refresh();
    })
  );

  // Migrate old env file SDK blocks to the new guarded template
  migrateEnvFile();

  // Configure terminal environment with resolved SDK PATH
  await updateTerminalEnv(context);

  // Watch .flutter-version for external changes
  const watcherDisposables = versionWatcher.start(() => {
    sdkProvider.refresh();
    updateTerminalEnv(context);
  });
  context.subscriptions.push(...watcherDisposables);

  // Refresh when workspace folders change
  context.subscriptions.push(
    vscode.workspace.onDidChangeWorkspaceFolders(() => {
      statusBar.refresh();
      sdkProvider.refresh();
      updateTerminalEnv(context);
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
        updateTerminalEnv(context);
      }
    })
  );
}

/**
 * Update the terminal environment with the resolved SDK PATH.
 *
 * Resolution order: project `.flutter-version` → global default.
 * New terminals opened in VS Code will have the correct `flutter` and
 * `dart` on PATH without relying on the static shell config block.
 */
async function updateTerminalEnv(
  context: vscode.ExtensionContext,
): Promise<void> {
  const env = context.environmentVariableCollection;
  env.persistent = true;

  const backend = getBackend();
  const sep = process.platform === "win32" ? ";" : ":";

  // Resolve: project .flutter-version first, then global
  let sdkVersion: string | undefined;

  const folders = vscode.workspace.workspaceFolders;
  if (folders && folders.length > 0) {
    const fvUri = vscode.Uri.joinPath(folders[0].uri, ".flutter-version");
    try {
      const bytes = await vscode.workspace.fs.readFile(fvUri);
      const content = Buffer.from(bytes).toString("utf-8").trim();
      if (content) {
        sdkVersion = content;
      }
    } catch {
      // No .flutter-version — fall through to global
    }
  }

  if (!sdkVersion) {
    sdkVersion = await backend.getGlobalSdkVersion();
  }

  if (!sdkVersion) {
    env.delete("PATH");
    env.delete("PUB_CACHE");
    env.delete("FLUTTER_COMPILE_SDK");
    return;
  }

  const sdkPath = await backend.getSdkPath(sdkVersion);
  if (!sdkPath) {
    env.delete("PATH");
    env.delete("PUB_CACHE");
    env.delete("FLUTTER_COMPILE_SDK");
    return;
  }

  const flutterBin = path.join(sdkPath, "bin");
  const dartBin = path.join(sdkPath, "bin", "cache", "dart-sdk", "bin");
  const pubCache = path.join(sdkPath, ".pub-cache");

  // Set the override env var so the env file's SDK block defers to it
  env.replace("FLUTTER_COMPILE_SDK", sdkPath);

  // Prepend SDK paths; applyAtShellIntegration ensures they survive shell init
  const shellOpts: vscode.EnvironmentVariableMutatorOptions = {
    applyAtShellIntegration: true,
  };
  env.prepend("PATH", `${flutterBin}${sep}${dartBin}${sep}`, shellOpts);
  env.replace("PUB_CACHE", pubCache, shellOpts);
}

export function deactivate(): void {
  statusBar.dispose();
  versionWatcher.stop();
}
