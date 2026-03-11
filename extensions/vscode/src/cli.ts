import * as vscode from "vscode";
import { exec } from "child_process";
import { promisify } from "util";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import type { DoctorCheck, EngineStatus } from "./types";
import type { SdkEntry } from "./sdkProvider";
export type { SdkEntry } from "./sdkProvider";

const execAsync = promisify(exec);

/**
 * Extract the first JSON token from CLI output.
 * The CLI may emit log lines (e.g. "MSG :", "FINE:", "SLVR:") on stdout
 * alongside the actual JSON payload. This finds the first line starting
 * with `[` or `{` and returns it.
 */
function extractJson(raw: string): string | undefined {
  for (const line of raw.split("\n")) {
    const trimmed = line.trimStart();
    if (trimmed.startsWith("[") || trimmed.startsWith("{")) {
      return trimmed;
    }
  }
  return undefined;
}

/**
 * Resolve the CLI executable path.
 * VS Code launched from Dock may not have ~/.pub-cache/bin on PATH.
 * Probe common locations like the IntelliJ extension does.
 */
let _resolvedCliPath: string | undefined;
function cliPath(): string {
  const configured = vscode.workspace
    .getConfiguration("flutterCompile")
    .get<string>("cliPath");
  if (configured && configured !== "flutter_compile") {
    return configured;
  }
  if (_resolvedCliPath) {
    return _resolvedCliPath;
  }
  const home = os.homedir();
  const candidates = [
    path.join(home, ".pub-cache", "bin", "flutter_compile"),
    ...(process.env.PUB_CACHE
      ? [path.join(process.env.PUB_CACHE, "bin", "flutter_compile")]
      : []),
    path.join(home, "flutter_compile", "flutter", "bin", "cache", "dart-sdk", "bin", "flutter_compile"),
  ];
  for (const candidate of candidates) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      _resolvedCliPath = candidate;
      return candidate;
    } catch {
      // not found, try next
    }
  }
  // Fallback: hope it's on PATH
  return "flutter_compile";
}

/** Build a PATH that includes common binary locations. */
function augmentedPath(): string {
  const home = os.homedir();
  const current = process.env.PATH || "";
  // Prepend pub-cache and depot_tools so the CLI and gclient are found.
  // Append flutter/bin AFTER current PATH so the system dart (used to
  // compile the CLI) is found first, avoiding Dart version mismatches.
  const prepend = [
    path.join(home, ".pub-cache", "bin"),
    path.join(home, "flutter_compile", "depot_tools"),
    "/usr/local/bin",
  ];
  const append = [
    path.join(home, "flutter_compile", "flutter", "bin"),
  ];
  return [...prepend, current, ...append].join(":");
}

/** Run `flutter_compile` with the given args and return stdout. */
async function run(args: string[]): Promise<string> {
  const cli = cliPath();
  const cmd = [cli, ...args].map((a) => `"${a}"`).join(" ");
  const { stdout } = await execAsync(cmd, {
    timeout: 120_000,
    maxBuffer: 10 * 1024 * 1024,
    env: { ...process.env, PATH: augmentedPath() },
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
    const json = extractJson(raw);
    if (!json) { return []; }
    return JSON.parse(json) as SdkEntry[];
  } catch {
    return [];
  }
}

/** Get the currently active global SDK version. */
export async function getGlobalSdkVersion(): Promise<string | undefined> {
  try {
    const raw = await run(["config", "get", "global_sdk"]);
    // Output format: "global_sdk_version:<version>" — may be buried in log noise
    for (const line of raw.split("\n")) {
      if (line.startsWith("global_sdk_version:")) {
        const value = line.substring("global_sdk_version:".length).trim();
        if (value) { return value; }
      }
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
    const json = extractJson(raw);
    if (!json) { return []; }
    return JSON.parse(json) as DoctorCheck[];
  } catch {
    return [];
  }
}

/** Get engine status via `status --json`. */
export async function getStatus(): Promise<EngineStatus> {
  try {
    const raw = await run(["status", "--json"]);
    const json = extractJson(raw);
    if (!json) { return { configured: false }; }
    return JSON.parse(json) as EngineStatus;
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

/** Delete a specific engine build output via `clean <name>`. */
export async function cleanBuild(buildName: string): Promise<void> {
  await run(["clean", buildName]);
}

/** Uninstall a contributor environment via `uninstall <type>`. */
export function uninstallEnvironment(type: "flutter" | "devtools" | "engine"): void {
  runInTerminal(["uninstall", type]);
}

/** Run `flutter_compile` with the given args and return stdout (public wrapper). */
export async function runCommand(args: string[]): Promise<string> {
  return run(args);
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
