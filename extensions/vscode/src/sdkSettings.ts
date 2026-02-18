import * as vscode from "vscode";
import * as cli from "./cli";

/**
 * Update `dart.flutterSdkPath` in workspace settings to point
 * to the given SDK version's install directory.
 */
export async function updateFlutterSdkPath(
  version: string
): Promise<void> {
  const sdkPath = await cli.getSdkPath(version);
  if (!sdkPath) {
    return;
  }

  const config = vscode.workspace.getConfiguration("dart");
  await config.update(
    "flutterSdkPath",
    sdkPath,
    vscode.ConfigurationTarget.Workspace
  );
}
