import * as vscode from "vscode";
import * as cli from "../cli";

export class CodePushTreeProvider
  implements vscode.TreeDataProvider<CodePushTreeItem>
{
  private _onDidChange = new vscode.EventEmitter<
    CodePushTreeItem | undefined | void
  >();
  readonly onDidChangeTreeData = this._onDidChange.event;

  refresh(): void {
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

    // Account status
    try {
      const accountJson = await cli.runCommand(["codepush", "account", "--json"]);
      const account = JSON.parse(accountJson);
      const tier = account.tier ?? "free";
      const icon =
        tier === "free" ? "$(circle-slash)" : "$(verified-filled)";
      items.push(
        new CodePushTreeItem(
          `${icon} Account: ${account.email ?? "Not logged in"}`,
          vscode.TreeItemCollapsibleState.None,
          "account",
          `Tier: ${tier}`
        )
      );
    } catch {
      items.push(
        new CodePushTreeItem(
          "$(circle-slash) Not logged in",
          vscode.TreeItemCollapsibleState.None,
          "account-none",
          'Run "fcp codepush login" to authenticate'
        )
      );
    }

    // App info
    try {
      const statusJson = await cli.runCommand(["codepush", "status", "--json"]);
      const status = JSON.parse(statusJson);
      const appName = status.app_name ?? status.app_id ?? "Unknown";
      items.push(
        new CodePushTreeItem(
          `$(package) App: ${appName}`,
          vscode.TreeItemCollapsibleState.None,
          "app",
          `ID: ${status.app_id ?? "none"}`
        )
      );
    } catch {
      items.push(
        new CodePushTreeItem(
          "$(package) No app configured",
          vscode.TreeItemCollapsibleState.None,
          "app-none",
          'Run "fcp codepush init" to create an app'
        )
      );
    }

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

  private async _getReleases(): Promise<CodePushTreeItem[]> {
    try {
      const statusJson = await cli.runCommand(["codepush", "status", "--json"]);
      const status = JSON.parse(statusJson);
      const releases = status.releases as Array<{
        id: string;
        version: string;
        created_at: string;
        patch_count?: number;
      }> ?? [];

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
      const data = JSON.parse(patchesJson);
      const patches = data.patches as Array<{
        id: string;
        number: number;
        rollout_percentage: number;
        is_active: boolean;
        created_at: string;
        patch_hash?: string;
      }> ?? [];

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

export class CodePushTreeItem extends vscode.TreeItem {
  releaseId?: string;
  patchId?: string;

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
