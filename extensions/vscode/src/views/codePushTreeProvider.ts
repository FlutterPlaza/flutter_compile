import * as vscode from "vscode";
import * as cli from "../cli";

interface SupportedVersion {
  version: string;
  build_revision?: string;
  installed: boolean;
  global: boolean;
  project_pinned: boolean;
}

interface SupportedVersionsResponse {
  selected: string | null;
  versions: SupportedVersion[];
  error?: string;
}

interface ReleaseEntry {
  id: string;
  version: string;
  created_at: string;
  patch_count?: number;
}

interface StatusResponse {
  configured?: boolean;
  logged_in?: boolean;
  app_id?: string;
  app_name?: string;
  releases?: ReleaseEntry[];
  total_patches?: number;
}

export class CodePushTreeProvider
  implements vscode.TreeDataProvider<CodePushTreeItem>
{
  private _onDidChange = new vscode.EventEmitter<
    CodePushTreeItem | undefined | void
  >();
  readonly onDidChangeTreeData = this._onDidChange.event;

  /** Cached status from the last root-items fetch so child lookups can
   *  reuse release metadata without re-hitting the CLI. */
  private _cachedStatus?: StatusResponse;

  refresh(): void {
    this._cachedStatus = undefined;
    this._onDidChange.fire();
  }

  getTreeItem(element: CodePushTreeItem): vscode.TreeItem {
    return element;
  }

  async getChildren(
    element?: CodePushTreeItem
  ): Promise<CodePushTreeItem[]> {
    if (!element) {
      return this._getRootItems();
    }
    if (element.contextValue === "versions-header") {
      return this._getSupportedVersions();
    }
    if (element.contextValue === "releases-header") {
      return this._getReleases();
    }
    if (element.contextValue === "release") {
      return this._getPatches(element.releaseId!);
    }
    return [];
  }

  private async _getRootItems(): Promise<CodePushTreeItem[]> {
    const items: CodePushTreeItem[] = [];

    // Supported Flutter Versions (always visible, at the top)
    items.push(
      new CodePushTreeItem(
        "$(versions) Supported Flutter Versions",
        vscode.TreeItemCollapsibleState.Expanded,
        "versions-header"
      )
    );

    // Account status
    try {
      const accountJson = await cli.runCommand(["codepush", "account", "--json"]);
      const account = JSON.parse(extractJson(accountJson)) as {
        logged_in?: boolean;
        email?: string;
        tier?: string;
      };
      if (account.logged_in) {
        const tier = account.tier ?? "free";
        const icon = tier === "free" ? "$(circle-slash)" : "$(verified-filled)";
        items.push(
          new CodePushTreeItem(
            `${icon} Account: ${account.email ?? "unknown"}`,
            vscode.TreeItemCollapsibleState.None,
            "account",
            `Tier: ${tier}`
          )
        );
      } else {
        items.push(this._notLoggedInItem());
        return items;
      }
    } catch {
      items.push(this._notLoggedInItem());
      return items;
    }

    // App info + releases section (logged in)
    let status: StatusResponse | undefined;
    try {
      const statusJson = await cli.runCommand(["codepush", "status", "--json"]);
      status = JSON.parse(extractJson(statusJson)) as StatusResponse;
      this._cachedStatus = status;
    } catch {
      // Fall through — treat as unconfigured
    }

    if (!status || status.configured !== true) {
      const item = new CodePushTreeItem(
        "$(package) No app configured",
        vscode.TreeItemCollapsibleState.None,
        "app-none",
        'Click to run "fcp codepush init"'
      );
      item.command = {
        command: "flutterCompile.codePushInit",
        title: "Init App",
      };
      items.push(item);
      return items;
    }

    const appName = status.app_name ?? status.app_id ?? "Unknown";
    items.push(
      new CodePushTreeItem(
        `$(package) App: ${appName}`,
        vscode.TreeItemCollapsibleState.None,
        "app",
        `ID: ${status.app_id ?? "none"}`
      )
    );

    // Patches summary row under the App node.
    const totalPatches = status.total_patches ?? 0;
    const releaseCount = status.releases?.length ?? 0;
    items.push(
      new CodePushTreeItem(
        `$(diff) Patches`,
        vscode.TreeItemCollapsibleState.None,
        "patches-summary",
        `${totalPatches} across ${releaseCount} release${releaseCount === 1 ? "" : "s"}`
      )
    );

    // Releases header
    items.push(
      new CodePushTreeItem(
        "$(tag) Releases",
        vscode.TreeItemCollapsibleState.Collapsed,
        "releases-header"
      )
    );

    return items;
  }

  private _notLoggedInItem(): CodePushTreeItem {
    const item = new CodePushTreeItem(
      "$(circle-slash) Not logged in",
      vscode.TreeItemCollapsibleState.None,
      "account-none",
      'Click to run "fcp codepush login"'
    );
    item.command = {
      command: "flutterCompile.codePushLogin",
      title: "Login",
    };
    return item;
  }

  private async _getSupportedVersions(): Promise<CodePushTreeItem[]> {
    try {
      const raw = await cli.runCommand(["codepush", "versions", "--json"]);
      const data = JSON.parse(extractJson(raw)) as SupportedVersionsResponse;
      if (data.error) {
        return [
          new CodePushTreeItem(
            "$(warning) Failed to load versions",
            vscode.TreeItemCollapsibleState.None,
            "error",
            data.error
          ),
        ];
      }
      const versions = data.versions ?? [];
      if (versions.length === 0) {
        return [
          new CodePushTreeItem(
            "No versions available",
            vscode.TreeItemCollapsibleState.None,
            "empty",
            "Check your code push server connection"
          ),
        ];
      }

      return versions.map((v) => {
        const isSelected = data.selected === v.version;
        let icon: string;
        let description: string;
        let contextValue: string;
        if (isSelected) {
          icon = "$(star-full)";
          description = "selected";
          contextValue = "cpVersionSelected";
        } else if (v.installed) {
          icon = "$(check)";
          description = "installed";
          contextValue = "cpVersionInstalled";
        } else {
          icon = "$(circle-large-outline)";
          description = "not installed";
          contextValue = "cpVersion";
        }
        const item = new CodePushTreeItem(
          `${icon} v${v.version}`,
          vscode.TreeItemCollapsibleState.None,
          contextValue,
          description
        );
        item.versionName = v.version;
        item.tooltip = v.build_revision
          ? `Flutter ${v.version} — build ${v.build_revision}`
          : `Flutter ${v.version}`;
        return item;
      });
    } catch {
      return [
        new CodePushTreeItem(
          "Failed to load versions",
          vscode.TreeItemCollapsibleState.None,
          "error"
        ),
      ];
    }
  }

  private async _getReleases(): Promise<CodePushTreeItem[]> {
    let status = this._cachedStatus;
    if (!status) {
      try {
        const raw = await cli.runCommand(["codepush", "status", "--json"]);
        status = JSON.parse(extractJson(raw)) as StatusResponse;
        this._cachedStatus = status;
      } catch {
        return [
          new CodePushTreeItem(
            "Failed to load releases",
            vscode.TreeItemCollapsibleState.None,
            "error"
          ),
        ];
      }
    }

    const releases = status?.releases ?? [];
    if (releases.length === 0) {
      return [
        new CodePushTreeItem(
          "No releases yet",
          vscode.TreeItemCollapsibleState.None,
          "empty"
        ),
      ];
    }

    return releases.map((r) => {
      const date = new Date(r.created_at).toLocaleDateString();
      const patchCount = r.patch_count ?? 0;
      const label = `v${r.version}`;
      const desc = `${date} — ${patchCount} patch${patchCount !== 1 ? "es" : ""}`;
      const item = new CodePushTreeItem(
        label,
        patchCount > 0
          ? vscode.TreeItemCollapsibleState.Collapsed
          : vscode.TreeItemCollapsibleState.None,
        "release",
        desc
      );
      item.releaseId = r.id;
      return item;
    });
  }

  private async _getPatches(
    releaseId: string
  ): Promise<CodePushTreeItem[]> {
    try {
      const patchesJson = await cli.runCommand([
        "codepush",
        "status",
        "--json",
        "--release-id",
        releaseId,
      ]);
      const data = JSON.parse(extractJson(patchesJson)) as {
        patches?: Array<{
          id: string;
          number: number;
          rollout_percentage: number;
          is_active: boolean;
          created_at: string;
          patch_hash?: string;
        }>;
      };
      const patches = data.patches ?? [];

      if (patches.length === 0) {
        return [
          new CodePushTreeItem(
            "No patches",
            vscode.TreeItemCollapsibleState.None,
            "empty"
          ),
        ];
      }

      return patches.map((p) => {
        const status = p.is_active ? "$(check)" : "$(x)";
        const rollout =
          p.rollout_percentage < 100 ? ` (${p.rollout_percentage}%)` : "";
        const label = `${status} Patch #${p.number}${rollout}`;
        const date = new Date(p.created_at).toLocaleDateString();
        const item = new CodePushTreeItem(
          label,
          vscode.TreeItemCollapsibleState.None,
          p.is_active ? "patch-active" : "patch-inactive",
          date
        );
        item.patchId = p.id;
        item.tooltip = `Patch ID: ${p.id}`;
        return item;
      });
    } catch {
      return [
        new CodePushTreeItem(
          "Failed to load patches",
          vscode.TreeItemCollapsibleState.None,
          "error"
        ),
      ];
    }
  }
}

/** Strip CLI log noise and return the first JSON object/array line. */
function extractJson(raw: string): string {
  for (const line of raw.split("\n")) {
    const trimmed = line.trimStart();
    if (trimmed.startsWith("[") || trimmed.startsWith("{")) {
      return trimmed;
    }
  }
  return raw;
}

export class CodePushTreeItem extends vscode.TreeItem {
  releaseId?: string;
  patchId?: string;
  versionName?: string;

  constructor(
    label: string,
    collapsibleState: vscode.TreeItemCollapsibleState,
    public readonly contextValue: string,
    description?: string
  ) {
    super(label, collapsibleState);
    this.description = description;
  }
}
