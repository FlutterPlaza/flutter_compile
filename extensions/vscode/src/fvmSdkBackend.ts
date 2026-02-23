import * as vscode from "vscode";
import { execFile } from "child_process";
import { promisify } from "util";
import type { SdkBackend, SdkEntry } from "./sdkProvider";

const execFileAsync = promisify(execFile);

/** Run `fvm` with the given args and return stdout. */
async function runFvm(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync("fvm", args, {
    timeout: 120_000,
  });
  return stdout.trim();
}

/** FVM `api list` response shape. */
interface FvmListResponse {
  versions: FvmVersion[];
}

interface FvmVersion {
  name: string;
  directory: string;
  releaseChannel?: string;
  type?: string;
}

/** FVM `api context` response shape. */
interface FvmContextResponse {
  global?: { version?: string; directory?: string };
  project?: { version?: string; directory?: string; pinnedVersion?: string; flavors?: Record<string, unknown> };
}

export class FvmSdkBackend implements SdkBackend {
  async listSdks(_projectRoot?: string): Promise<SdkEntry[]> {
    try {
      const raw = await runFvm(["api", "list"]);
      const data = JSON.parse(raw) as FvmListResponse;
      const versions = data.versions ?? [];

      // Get context for global/project markers
      let globalVersion: string | undefined;
      let projectVersion: string | undefined;
      try {
        const ctxRaw = await runFvm(["api", "context"]);
        const ctx = JSON.parse(ctxRaw) as FvmContextResponse;
        globalVersion = ctx.global?.version;
        projectVersion = ctx.project?.pinnedVersion ?? ctx.project?.version;
      } catch {
        // context may fail if no project
      }

      return versions.map((v) => ({
        version: v.name,
        path: v.directory,
        global: v.name === globalVersion,
        project: v.name === projectVersion,
        contributor: false,
      }));
    } catch {
      return [];
    }
  }

  async getGlobalSdkVersion(): Promise<string | undefined> {
    try {
      const raw = await runFvm(["api", "context"]);
      const ctx = JSON.parse(raw) as FvmContextResponse;
      return ctx.global?.version ?? undefined;
    } catch {
      return undefined;
    }
  }

  async setGlobalSdk(version: string): Promise<void> {
    await runFvm(["global", version]);
  }

  installSdkInTerminal(version: string): void {
    const terminal = vscode.window.createTerminal("FVM Install");
    terminal.sendText(`fvm install ${version}`);
    terminal.show();
  }

  async removeSdk(version: string): Promise<void> {
    await runFvm(["remove", version]);
  }

  async pinToProject(version: string, projectRoot: string): Promise<void> {
    await runFvm(["use", version, "--project", projectRoot]);
  }

  async getSdkPath(version: string): Promise<string | undefined> {
    try {
      const raw = await runFvm(["api", "list"]);
      const data = JSON.parse(raw) as FvmListResponse;
      const match = (data.versions ?? []).find((v) => v.name === version);
      return match?.directory;
    } catch {
      return undefined;
    }
  }

  async isSdkInstalled(version: string): Promise<boolean> {
    try {
      const raw = await runFvm(["api", "list"]);
      const data = JSON.parse(raw) as FvmListResponse;
      return (data.versions ?? []).some((v) => v.name === version);
    } catch {
      return false;
    }
  }
}
