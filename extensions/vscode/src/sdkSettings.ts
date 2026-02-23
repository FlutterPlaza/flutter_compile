import * as vscode from "vscode";
import { getBackend } from "./sdkProvider";

/**
 * Update `dart.flutterSdkPath` in workspace settings to point
 * to the given SDK version's install directory.
 */
export async function updateFlutterSdkPath(
  version: string
): Promise<void> {
  const sdkPath = await getBackend().getSdkPath(version);
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
