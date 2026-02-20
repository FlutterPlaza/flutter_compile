import * as vscode from "vscode";
import { execFile } from "child_process";
import { promisify } from "util";
import type { DoctorCheck, EngineStatus } from "./types";

const execFileAsync = promisify(execFile);

/** Installed SDK entry returned by `sdk list --json`. */
export interface SdkEntry {
  version: string;
  path: string;
  global: boolean;
  project: boolean;
  contributor: boolean;
}

/** Returns the configured CLI executable path. */
function cliPath(): string {
  return (
    vscode.workspace
      .getConfiguration("flutterCompile")
      .get<string>("cliPath") ?? "flutter_compile"
  );
}

/** Run `flutter_compile` with the given args and return stdout. */
async function run(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync(cliPath(), args, {
    timeout: 120_000,
  });
  return stdout.trim();
}

/** Run `flutter_compile` in a VS Code terminal (visible output). */
export function runInTerminal(args: string[]): void {
  const terminal = vscode.window.createTerminal("Flutter Compile");
  terminal.sendText(`${cliPath()} ${args.join(" ")}`);
  terminal.show();
}

/** Get installed SDKs via `sdk list --json`. */
export async function listSdks(): Promise<SdkEntry[]> {
  try {
    const raw = await run(["sdk", "list", "--json"]);
    return JSON.parse(raw) as SdkEntry[];
  } catch {
    return [];
  }
}

/** Get the currently active global SDK version. */
export async function getGlobalSdkVersion(): Promise<string | undefined> {
  try {
    const raw = await run(["config", "get", "global_sdk"]);
    // Output format: "global_sdk_version:<version>"
    const parts = raw.split(":");
    if (parts.length === 2 && parts[1].trim()) {
      return parts[1].trim();
    }
    return undefined;
  } catch {
    return undefined;
  }
}

/** Set global SDK version via `sdk global <version>`. */
export async function setGlobalSdk(version: string): Promise<void> {
  await run(["sdk", "global", version]);
}

/** Install an SDK via `sdk install <version>`. */
export function installSdk(version: string): void {
  runInTerminal(["sdk", "install", version]);
}

/** Run doctor and return raw output. */
export async function runDoctor(): Promise<string> {
  try {
    return await run(["doctor"]);
  } catch (e) {
    return `Error running doctor: ${e}`;
  }
}

/** Resolve the SDK path for a given version. */
export async function getSdkPath(
  version: string
): Promise<string | undefined> {
  const sdks = await listSdks();
  const match = sdks.find((s) => s.version === version);
  return match?.path;
}

/** Run doctor with JSON output. */
export async function runDoctorJson(): Promise<DoctorCheck[]> {
  try {
    const raw = await run(["doctor", "--json"]);
    return JSON.parse(raw) as DoctorCheck[];
  } catch {
    return [];
  }
}

/** Get engine status via `status --json`. */
export async function getStatus(): Promise<EngineStatus> {
  try {
    const raw = await run(["status", "--json"]);
    return JSON.parse(raw) as EngineStatus;
  } catch {
    return { configured: false };
  }
}

/** Remove an installed SDK via `sdk remove <version>`. */
export async function removeSdk(version: string): Promise<void> {
  await run(["sdk", "remove", version]);
}

/** Pin SDK to project via `sdk use <version>`. */
export async function useSdk(version: string): Promise<void> {
  await run(["sdk", "use", version]);
}

/** Check if the CLI is available. */
export async function isCliAvailable(): Promise<boolean> {
  try {
    await run(["--version"]);
    return true;
  } catch {
    return false;
  }
}
