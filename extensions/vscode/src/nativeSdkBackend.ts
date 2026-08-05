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

const SDK_PATH_BLOCK_START =
  "# >>> Added by flutter_compile SDK manager >>>";
const SDK_PATH_BLOCK_END =
  "# <<< Added by flutter_compile SDK manager <<<";

const ENV_FILE = ".flutter_compile_env";
const DEFAULT_SDK_LINK = "default";

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
// Shell config helpers (PATH management)
// ---------------------------------------------------------------------------

/** Detect the user's shell config file path. */
function shellConfigPath(): string {
  const home = homeDir();
  if (process.platform === "win32") {
    const docs = process.env.USERPROFILE ?? home;
    return path.join(
      docs,
      "Documents",
      "WindowsPowerShell",
      "Microsoft.PowerShell_profile.ps1",
    );
  }
  const shell = process.env.SHELL ?? "";
  const rc = shell.includes("bash")
    ? ".bashrc"
    : shell.includes("zsh")
      ? ".zshrc"
      : ".profile";
  return path.join(home, rc);
}

/** Returns the path to the dedicated env file (~/.flutter_compile_env). */
function envFilePath(): string {
  return path.join(homeDir(), ENV_FILE);
}

/** Source line added to the user's shell RC. */
const SOURCE_LINE = `\n[ -f ~/.${ENV_FILE} ] && source ~/.${ENV_FILE}\n`;
const SOURCE_LINE_WINDOWS = `\nif (Test-Path "$HOME\\.${ENV_FILE}") { . "$HOME\\.${ENV_FILE}" }\n`;

/** Regex to detect the source line already present in shell RC. */
const SOURCE_LINE_RE =
  process.platform === "win32"
    ? /\n?if \(Test-Path "\$HOME\\\.flutter_compile_env"\) \{ \. "\$HOME\\\.flutter_compile_env" \}\n?/
    : /\n?\[ *-f *~\/\.flutter_compile_env *\] *&& *source *~\/\.flutter_compile_env\n?/;

/** Regex that matches the SDK manager PATH block. */
const SDK_PATH_BLOCK_RE = new RegExp(
  "\\n?# >>> Added by flutter_compile SDK manager >>>" +
    "[\\s\\S]*?" +
    "# <<< Added by flutter_compile SDK manager <<<\\n?",
);

/**
 * Idempotently ensure the shell RC has a `source` line for the env file.
 * Also strips any legacy SDK manager PATH blocks from the shell RC as migration.
 */
function ensureSourceLine(): void {
  const configFile = shellConfigPath();
  let contents = "";
  try {
    contents = fs.readFileSync(configFile, "utf-8");
  } catch {
    // File doesn't exist yet
  }

  let changed = false;

  // Migration: remove old SDK manager blocks from shell RC
  if (SDK_PATH_BLOCK_RE.test(contents)) {
    contents = contents.replace(SDK_PATH_BLOCK_RE, "");
    changed = true;
  }

  // Add source line if not already present
  if (!SOURCE_LINE_RE.test(contents)) {
    const line =
      process.platform === "win32" ? SOURCE_LINE_WINDOWS : SOURCE_LINE;
    contents += line;
    changed = true;
  }

  if (changed) {
    const dir = path.dirname(configFile);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    fs.writeFileSync(configFile, contents, "utf-8");
  }
}

/** Build the SDK PATH export block for the given SDK path. */
function buildSdkPathBlock(sdkDir: string, pubCachePath: string): string {
  if (process.platform === "win32") {
    return [
      "",
      SDK_PATH_BLOCK_START,
      `if (-not $env:FLUTTER_COMPILE_SDK) {`,
      `  $env:PATH = "${sdkDir}\\bin;$env:PATH"`,
      `  $env:PATH = "${sdkDir}\\bin\\cache\\dart-sdk\\bin;$env:PATH"`,
      `  $env:PUB_CACHE = "${pubCachePath}"`,
      `} else {`,
      `  $env:PATH = "$env:FLUTTER_COMPILE_SDK\\bin;$env:FLUTTER_COMPILE_SDK\\bin\\cache\\dart-sdk\\bin;$env:PATH"`,
      `  $env:PUB_CACHE = "$env:FLUTTER_COMPILE_SDK\\.pub-cache"`,
      `}`,
      SDK_PATH_BLOCK_END,
      "",
    ].join("\n");
  }
  return [
    "",
    SDK_PATH_BLOCK_START,
    `if [ -z "$FLUTTER_COMPILE_SDK" ]; then`,
    `  export PATH="${sdkDir}/bin:$PATH"`,
    `  export PATH="${sdkDir}/bin/cache/dart-sdk/bin:$PATH"`,
    `  export PUB_CACHE="${pubCachePath}"`,
    `else`,
    `  export PATH="$FLUTTER_COMPILE_SDK/bin:$FLUTTER_COMPILE_SDK/bin/cache/dart-sdk/bin:$PATH"`,
    `  export PUB_CACHE="$FLUTTER_COMPILE_SDK/.pub-cache"`,
    `fi`,
    SDK_PATH_BLOCK_END,
    "",
  ].join("\n");
}

/** Write the SDK PATH block into the env file, replacing any existing block. */
function updateShellConfigPath(sdkDir: string, pubCachePath: string): void {
  if (!isFlutterSdk(sdkDir)) {
    console.warn(
      `Refusing to update shell config: "${sdkDir}" is not a valid Flutter SDK.`,
    );
    return;
  }

  ensureSourceLine();

  const envFile = envFilePath();
  let contents = "";
  try {
    contents = fs.readFileSync(envFile, "utf-8");
  } catch {
    // File doesn't exist yet — start with empty string
  }

  // Remove existing block
  contents = contents.replace(SDK_PATH_BLOCK_RE, "");

  // Append new block
  contents += buildSdkPathBlock(sdkDir, pubCachePath);

  const dir = path.dirname(envFile);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(envFile, contents, "utf-8");
}

/** Remove the SDK PATH block from the env file and legacy shell RC. */
function removeShellConfigPath(): void {
  // Clean env file
  const envFile = envFilePath();
  if (fs.existsSync(envFile)) {
    let contents = fs.readFileSync(envFile, "utf-8");
    contents = contents.replace(SDK_PATH_BLOCK_RE, "");
    fs.writeFileSync(envFile, contents, "utf-8");
  }

  // Migration: also strip legacy block from shell RC
  const configFile = shellConfigPath();
  if (fs.existsSync(configFile)) {
    let contents = fs.readFileSync(configFile, "utf-8");
    if (SDK_PATH_BLOCK_RE.test(contents)) {
      contents = contents.replace(SDK_PATH_BLOCK_RE, "");
      fs.writeFileSync(configFile, contents, "utf-8");
    }
  }
}

// ---------------------------------------------------------------------------
// Env file migration
// ---------------------------------------------------------------------------

/**
 * Migrate the env file: rewrite old-style SDK blocks with the new
 * FLUTTER_COMPILE_SDK-guarded template. No-op if already migrated.
 *
 * Called once on extension activation so that existing users get the
 * project-pin fix without having to re-set their global SDK.
 */
export function migrateEnvFile(): void {
  const envFile = envFilePath();
  let contents = "";
  try {
    contents = fs.readFileSync(envFile, "utf-8");
  } catch {
    return; // No env file, nothing to migrate
  }

  // Nothing to migrate if no SDK block or already guarded
  if (
    !SDK_PATH_BLOCK_RE.test(contents) ||
    contents.includes("FLUTTER_COMPILE_SDK")
  ) {
    return;
  }

  // Resolve the global SDK to rewrite the block with the new template
  const globalVersion = readRcConfigValue(GLOBAL_SDK_KEY);
  if (!globalVersion || !globalVersion.trim()) {
    return;
  }

  // Use fallback scan to handle directories with trailing whitespace
  const trimmed = globalVersion.trim();
  let sdkDir = sdkVersionPath(trimmed);
  if (!fs.existsSync(sdkDir)) {
    // Fallback: scan versions dir for trimmed name match, renaming if needed
    const vDir = versionsDir();
    let found = false;
    if (fs.existsSync(vDir)) {
      try {
        for (const d of fs.readdirSync(vDir, { withFileTypes: true })) {
          if (d.isDirectory() && d.name.trim() === trimmed && d.name !== trimmed) {
            try {
              fs.renameSync(path.join(vDir, d.name), sdkDir);
            } catch {
              sdkDir = path.join(vDir, d.name);
            }
            found = true;
            break;
          }
        }
      } catch {
        // ignore
      }
    }
    if (!found) {
      return;
    }
  }

  const pubCache = path.join(sdkDir, ".pub-cache");
  updateShellConfigPath(sdkDir, pubCache);
}

// ---------------------------------------------------------------------------
// Git helpers
// ---------------------------------------------------------------------------

/**
 * Returns true if the path contains a usable Flutter SDK (`bin/flutter`).
 *
 * Checks for the flutter executable rather than `.git/HEAD` so that SDKs
 * installed from release archives (no `.git`) still work.
 */
function isFlutterSdk(sdkPath: string): boolean {
  const flutter =
    process.platform === "win32"
      ? path.join(sdkPath, "bin", "flutter.bat")
      : path.join(sdkPath, "bin", "flutter");
  try {
    return fs.statSync(flutter).isFile();
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Default symlink helpers
// ---------------------------------------------------------------------------

/** Create or update the `default` symlink to point to `sdkDir`. */
function updateDefaultSdkLink(sdkDir: string): void {
  const linkPath = path.join(versionsDir(), DEFAULT_SDK_LINK);
  try {
    const stat = fs.lstatSync(linkPath);
    if (stat.isSymbolicLink()) {
      fs.unlinkSync(linkPath);
    } else if (stat.isDirectory()) {
      return; // real directory — don't touch
    }
  } catch {
    // does not exist — fine
  }
  fs.symlinkSync(sdkDir, linkPath, "dir");
}

/** Remove the `default` symlink if it exists. */
function removeDefaultSdkLink(): void {
  const linkPath = path.join(versionsDir(), DEFAULT_SDK_LINK);
  try {
    const stat = fs.lstatSync(linkPath);
    if (stat.isSymbolicLink()) {
      fs.unlinkSync(linkPath);
    }
  } catch {
    // does not exist — fine
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

    let entries: { name: string; dirName: string }[];
    try {
      entries = fs
        .readdirSync(vDir, { withFileTypes: true })
        .filter((d) => d.isDirectory() && d.name !== DEFAULT_SDK_LINK)
        .map((d) => ({ name: d.name.trim(), dirName: d.name }))
        .sort((a, b) => a.name.localeCompare(b.name));
    } catch {
      return [];
    }

    if (entries.length === 0) {
      return [];
    }

    const globalVersion = readRcConfigValue(GLOBAL_SDK_KEY)?.trim();

    let projectVersion: string | undefined;
    const root = projectRoot ?? vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    if (root) {
      const fvFile = path.join(root, FLUTTER_VERSION_FILE);
      if (fs.existsSync(fvFile)) {
        projectVersion = fs.readFileSync(fvFile, "utf-8").trim() || undefined;
      }
    }

    const sdks: SdkEntry[] = entries.map((e) => ({
      version: e.name,
      path: path.join(vDir, e.dirName),
      global: e.name === globalVersion,
      project: e.name === projectVersion,
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
    const sdkDir = await this.getSdkPath(version);
    if (!sdkDir || !isFlutterSdk(sdkDir)) {
      throw new Error(`SDK "${version}" is not installed.`);
    }
    writeRcConfigKey(GLOBAL_SDK_KEY, version);

    // Update shell config so new terminal sessions use this SDK
    const pubCachePath = path.join(sdkDir, ".pub-cache");
    updateShellConfigPath(sdkDir, pubCachePath);

    // Update the `default` symlink
    updateDefaultSdkLink(sdkDir);
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
    if (["compiled", "engine"].includes(version.trim())) {
      throw new Error(
        '"compiled" is the contributor environment — remove it with ' +
          '"Flutter Compile: Uninstall", not the SDK manager.'
      );
    }
    const sdkDir = sdkVersionPath(version);
    if (!fs.existsSync(sdkDir)) {
      throw new Error(`SDK "${version}" is not installed.`);
    }

    fs.rmSync(sdkDir, { recursive: true, force: true });

    // If it was the global version, clear the config and shell PATH
    const globalVersion = readRcConfigValue(GLOBAL_SDK_KEY);
    if (globalVersion === version) {
      removeRcConfigKey(GLOBAL_SDK_KEY);
      removeShellConfigPath();
      removeDefaultSdkLink();
    }
  }

  async pinToProject(version: string, projectRoot: string): Promise<void> {
    const sdkPath = await this.getSdkPath(version);
    if (!sdkPath || !isFlutterSdk(sdkPath)) {
      throw new Error(`SDK "${version}" is not installed.`);
    }
    const filePath = path.join(projectRoot, FLUTTER_VERSION_FILE);
    fs.writeFileSync(filePath, `${version}\n`, "utf-8");
  }

  async unpinFromProject(projectRoot: string): Promise<void> {
    const filePath = path.join(projectRoot, FLUTTER_VERSION_FILE);
    try {
      fs.rmSync(filePath);
    } catch {
      // File doesn't exist — nothing to do
    }
  }

  async getSdkPath(version: string): Promise<string | undefined> {
    const trimmed = version.trim();
    // Contributor environment: the from-source checkout created by
    // `install flutter`, selectable under the fixed name "compiled".
    if (trimmed === "compiled") {
      const checkout = path.join(homeDir(), "flutter_compile", "flutter");
      return fs.existsSync(checkout) ? checkout : undefined;
    }
    const sdkPath = sdkVersionPath(trimmed);
    if (fs.existsSync(sdkPath)) {
      return sdkPath;
    }

    // Fallback: scan versions dir for a directory whose trimmed name matches.
    // When found, rename to the canonical name so trailing whitespace doesn't
    // leak into shell config files.
    const vDir = versionsDir();
    if (fs.existsSync(vDir)) {
      try {
        for (const d of fs.readdirSync(vDir, { withFileTypes: true })) {
          if (d.isDirectory() && d.name.trim() === trimmed && d.name !== trimmed) {
            try {
              fs.renameSync(path.join(vDir, d.name), sdkPath);
            } catch {
              return path.join(vDir, d.name); // rename failed — return raw path
            }
            return sdkPath;
          }
        }
      } catch {
        // ignore
      }
    }

    // Also check the compiled environment
    if (trimmed === "compiled") {
      const compiledDir = path.join(homeDir(), "flutter_compile", "flutter");
      if (fs.existsSync(compiledDir)) {
        return compiledDir;
      }
    }
    return undefined;
  }

  async isSdkInstalled(version: string): Promise<boolean> {
    const sdkPath = await this.getSdkPath(version);
    return sdkPath != null && isFlutterSdk(sdkPath);
  }
}
