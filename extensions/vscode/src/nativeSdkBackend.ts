import * as vscode from "vscode";
import * as os from "os";
import * as path from "path";
import * as fs from "fs";
import type { SdkBackend, SdkEntry } from "./sdkProvider";

const FLUTTER_GIT_URL = "https://github.com/flutter/flutter.git";
const SDK_VERSIONS_REL = "flutter_compile/versions";
const RC_FILE = ".flutter_compilerc";
const GLOBAL_SDK_KEY = "global_sdk_version";
const FLUTTER_VERSION_FILE = ".flutter-version";

/** Returns the user's home directory. */
function homeDir(): string {
  return os.homedir();
}

/** Returns the SDK versions directory (`~/flutter_compile/versions`). */
function versionsDir(): string {
  return path.join(homeDir(), SDK_VERSIONS_REL);
}

/** Returns the absolute install path for a given SDK version. */
function sdkVersionPath(version: string): string {
  return path.join(versionsDir(), version);
}

/** Returns the RC config file path (`~/.flutter_compilerc`). */
function rcFilePath(): string {
  return path.join(homeDir(), RC_FILE);
}

// ---------------------------------------------------------------------------
// RC config helpers
// ---------------------------------------------------------------------------

/** Read the rc config file as a key-value map. */
function readRcConfig(): Map<string, string> {
  const map = new Map<string, string>();
  const filePath = rcFilePath();
  if (!fs.existsSync(filePath)) {
    return map;
  }
  const content = fs.readFileSync(filePath, "utf-8");
  for (const line of content.split("\n")) {
    const colonIndex = line.indexOf(":");
    if (colonIndex !== -1) {
      map.set(line.substring(0, colonIndex), line.substring(colonIndex + 1));
    }
  }
  return map;
}

/** Write a key-value pair to the rc config, preserving existing entries. */
function writeRcConfigKey(key: string, value: string): void {
  const map = readRcConfig();
  map.set(key, value);
  const lines: string[] = [];
  map.forEach((v, k) => lines.push(`${k}:${v}`));
  const dir = path.dirname(rcFilePath());
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(rcFilePath(), lines.join("\n") + "\n", "utf-8");
}

/** Remove a key from the rc config. */
function removeRcConfigKey(key: string): void {
  const filePath = rcFilePath();
  if (!fs.existsSync(filePath)) {
    return;
  }
  const content = fs.readFileSync(filePath, "utf-8");
  const filtered = content
    .split("\n")
    .filter((line) => {
      const colonIndex = line.indexOf(":");
      if (colonIndex === -1) {
        return line.trim().length > 0;
      }
      return line.substring(0, colonIndex) !== key;
    });
  fs.writeFileSync(filePath, filtered.join("\n") + "\n", "utf-8");
}

/** Read a single key value from the rc config. */
function readRcConfigValue(key: string): string | undefined {
  const map = readRcConfig();
  return map.get(key);
}

// ---------------------------------------------------------------------------
// Git helpers
// ---------------------------------------------------------------------------

/** Returns true if the path is a directory containing `.git/HEAD`. */
function isValidGitRepo(dirPath: string): boolean {
  try {
    return fs.statSync(path.join(dirPath, ".git", "HEAD")).isFile();
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Native SDK Backend
// ---------------------------------------------------------------------------

export class NativeSdkBackend implements SdkBackend {
  async listSdks(projectRoot?: string): Promise<SdkEntry[]> {
    const vDir = versionsDir();
    if (!fs.existsSync(vDir)) {
      return [];
    }

    let entries: string[];
    try {
      entries = fs
        .readdirSync(vDir, { withFileTypes: true })
        .filter((d) => d.isDirectory())
        .map((d) => d.name)
        .sort();
    } catch {
      return [];
    }

    if (entries.length === 0) {
      return [];
    }

    const globalVersion = readRcConfigValue(GLOBAL_SDK_KEY);

    let projectVersion: string | undefined;
    const root = projectRoot ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (root) {
      const fvFile = path.join(root, FLUTTER_VERSION_FILE);
      if (fs.existsSync(fvFile)) {
        projectVersion = fs.readFileSync(fvFile, "utf-8").trim() || undefined;
      }
    }

    const sdks: SdkEntry[] = entries.map((name) => ({
      version: name,
      path: path.join(vDir, name),
      global: name === globalVersion,
      project: name === projectVersion,
      contributor: false,
    }));

    // Check for contributor (compiled) environment
    const compiledDir = path.join(homeDir(), "flutter_compile", "flutter");
    if (fs.existsSync(compiledDir)) {
      sdks.push({
        version: "compiled",
        path: compiledDir,
        global: "compiled" === globalVersion,
        project: "compiled" === projectVersion,
        contributor: true,
      });
    }

    return sdks;
  }

  async getGlobalSdkVersion(): Promise<string | undefined> {
    const value = readRcConfigValue(GLOBAL_SDK_KEY);
    return value && value.trim() ? value.trim() : undefined;
  }

  async setGlobalSdk(version: string): Promise<void> {
    const sdkPath = await this.getSdkPath(version);
    if (!sdkPath || !isValidGitRepo(sdkPath)) {
      throw new Error(`SDK "${version}" is not installed.`);
    }
    writeRcConfigKey(GLOBAL_SDK_KEY, version);
  }

  installSdkInTerminal(version: string): void {
    const target = sdkVersionPath(version);
    const vDir = versionsDir();
    const pubCache = path.join(target, ".pub-cache");

    // Build a shell script that clones, checks out, and caches the SDK
    const commands = [
      `mkdir -p "${vDir}"`,
      `git clone "${FLUTTER_GIT_URL}" "${target}"`,
      `cd "${target}" && git checkout ${version}`,
      `export PUB_CACHE="${pubCache}"`,
      `"${target}/bin/flutter" --version`,
    ];

    const terminal = vscode.window.createTerminal("Flutter SDK Install");
    terminal.sendText(commands.join(" && "));
    terminal.show();
  }

  async removeSdk(version: string): Promise<void> {
    const sdkPath = sdkVersionPath(version);
    if (!fs.existsSync(sdkPath)) {
      throw new Error(`SDK "${version}" is not installed.`);
    }

    fs.rmSync(sdkPath, { recursive: true, force: true });

    // If it was the global version, clear the config
    const globalVersion = readRcConfigValue(GLOBAL_SDK_KEY);
    if (globalVersion === version) {
      removeRcConfigKey(GLOBAL_SDK_KEY);
    }
  }

  async pinToProject(version: string, projectRoot: string): Promise<void> {
    const sdkPath = await this.getSdkPath(version);
    if (!sdkPath || !isValidGitRepo(sdkPath)) {
      throw new Error(`SDK "${version}" is not installed.`);
    }
    const filePath = path.join(projectRoot, FLUTTER_VERSION_FILE);
    fs.writeFileSync(filePath, `${version}\n`, "utf-8");
  }

  async getSdkPath(version: string): Promise<string | undefined> {
    const sdkPath = sdkVersionPath(version);
    if (fs.existsSync(sdkPath)) {
      return sdkPath;
    }
    // Also check the compiled environment
    if (version === "compiled") {
      const compiledDir = path.join(homeDir(), "flutter_compile", "flutter");
      if (fs.existsSync(compiledDir)) {
        return compiledDir;
      }
    }
    return undefined;
  }

  async isSdkInstalled(version: string): Promise<boolean> {
    return isValidGitRepo(sdkVersionPath(version));
  }
}
