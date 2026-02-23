import * as vscode from "vscode";

/** Installed SDK entry shared across backends. */
export interface SdkEntry {
  version: string;
  path: string;
  global: boolean;
  project: boolean;
  contributor: boolean;
}

/** Backend interface that all SDK managers must implement. */
export interface SdkBackend {
  listSdks(projectRoot?: string): Promise<SdkEntry[]>;
  getGlobalSdkVersion(): Promise<string | undefined>;
  setGlobalSdk(version: string): Promise<void>;
  installSdkInTerminal(version: string): void;
  removeSdk(version: string): Promise<void>;
  pinToProject(version: string, projectRoot: string): Promise<void>;
  getSdkPath(version: string): Promise<string | undefined>;
  isSdkInstalled(version: string): Promise<boolean>;
}

export type SdkManagerMode = "native" | "fvm";

/** Returns the configured SDK manager mode. */
export function getMode(): SdkManagerMode {
  return (
    vscode.workspace
      .getConfiguration("flutterCompile")
      .get<SdkManagerMode>("sdkManager") ?? "native"
  );
}

let _backend: SdkBackend | undefined;
let _currentMode: SdkManagerMode | undefined;

/** Returns the active SDK backend based on the `flutterCompile.sdkManager` setting. */
export function getBackend(): SdkBackend {
  const mode = getMode();
  if (_backend && _currentMode === mode) {
    return _backend;
  }
  _currentMode = mode;
  if (mode === "fvm") {
    // Lazy import to avoid loading FVM backend if not needed
    const { FvmSdkBackend } = require("./fvmSdkBackend");
    _backend = new FvmSdkBackend();
  } else {
    const { NativeSdkBackend } = require("./nativeSdkBackend");
    _backend = new NativeSdkBackend();
  }
  return _backend!;
}

/** Force-reload the backend (e.g. after a setting change). */
export function reloadBackend(): void {
  _backend = undefined;
  _currentMode = undefined;
}
