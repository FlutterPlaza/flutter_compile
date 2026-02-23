import * as vscode from "vscode";
import type { DoctorCheck } from "../types";
import * as cli from "../cli";
import { BuildEntryItem } from "./buildsTreeProvider";

type DoctorNode = CategoryItem | CheckItem | BuildsCategoryItem | BuildEntryItem;

const CATEGORY_LABELS: Record<string, string> = {
  tools: "Required Tools",
  engine_tools: "Engine Tools",
  config: "Configuration",
  environments: "Environments",
};

class CategoryItem extends vscode.TreeItem {
  constructor(
    public readonly category: string,
    public readonly checks: DoctorCheck[]
  ) {
    super(
      CATEGORY_LABELS[category] ?? category,
      vscode.TreeItemCollapsibleState.Expanded
    );

    const okCount = checks.filter((c) => c.status === "ok").length;
    const total = checks.length;
    this.description = `${okCount}/${total} OK`;

    if (okCount === total) {
      this.iconPath = new vscode.ThemeIcon(
        "pass-filled",
        new vscode.ThemeColor("charts.green")
      );
    } else {
      this.iconPath = new vscode.ThemeIcon(
        "error",
        new vscode.ThemeColor("charts.red")
      );
    }
  }
}

class BuildsCategoryItem extends vscode.TreeItem {
  constructor(public readonly buildCount: number) {
    super("Engine Builds", vscode.TreeItemCollapsibleState.Expanded);
    this.description = `${buildCount} build${buildCount !== 1 ? "s" : ""}`;
    this.iconPath = new vscode.ThemeIcon("package");
  }
}

export class CheckItem extends vscode.TreeItem {
  constructor(public readonly check: DoctorCheck) {
    super(check.name, vscode.TreeItemCollapsibleState.None);

    switch (check.status) {
      case "ok":
        this.iconPath = new vscode.ThemeIcon(
          "check",
          new vscode.ThemeColor("charts.green")
        );
        this.description = check.path ? "installed" : "ok";
        break;
      case "missing":
      case "not_found":
        this.iconPath = new vscode.ThemeIcon(
          "close",
          new vscode.ThemeColor("charts.red")
        );
        this.description = "not installed";
        break;
      case "not_configured":
      case "missing_remotes":
      case "not_git_repo":
        this.iconPath = new vscode.ThemeIcon(
          "warning",
          new vscode.ThemeColor("charts.yellow")
        );
        this.description = check.status.replace(/_/g, " ");
        break;
      case "invalid":
      case "error":
        this.iconPath = new vscode.ThemeIcon(
          "close",
          new vscode.ThemeColor("charts.red")
        );
        this.description = check.error ?? check.status;
        break;
      default:
        this.iconPath = new vscode.ThemeIcon("dash");
        this.description = check.status;
    }

    // Set contextValue — environment items get distinct values for uninstall action
    if (check.category === "environments") {
      this.contextValue = check.status === "ok" ? "envOk" : "envFailing";
    } else {
      this.contextValue = check.status === "ok" ? "doctorCheckOk" : "doctorCheckFailing";
    }

    const lines = [`**${check.name}**`, `Status: ${check.status}`];
    if (check.path) {
      lines.push(`Path: \`${check.path}\``);
    }
    if (check.error) {
      lines.push(`Error: ${check.error}`);
    }
    if (check.missing_remotes && check.missing_remotes.length > 0) {
      lines.push(`Missing remotes: ${check.missing_remotes.join(", ")}`);
    }
    this.tooltip = new vscode.MarkdownString(lines.join("\n\n"));
  }
}

export class DoctorTreeProvider
  implements vscode.TreeDataProvider<DoctorNode>
{
  private _onDidChangeTreeData = new vscode.EventEmitter<
    DoctorNode | undefined | void
  >();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  private checks: DoctorCheck[] = [];
  private builds: { name: string; size: string }[] = [];

  refresh(): void {
    this._onDidChangeTreeData.fire();
  }

  getTreeItem(element: DoctorNode): vscode.TreeItem {
    return element;
  }

  async getChildren(element?: DoctorNode): Promise<DoctorNode[]> {
    if (element instanceof CategoryItem) {
      return element.checks.map((c) => new CheckItem(c));
    }

    if (element instanceof BuildsCategoryItem) {
      return this.builds.map((b) => new BuildEntryItem(b.name, b.size));
    }

    // Root level — fetch doctor checks and engine status in parallel
    const [checks, status] = await Promise.all([
      cli.runDoctorJson(),
      cli.getStatus(),
    ]);

    this.checks = checks;
    this.builds = status.builds ?? [];

    const groups = new Map<string, DoctorCheck[]>();
    for (const check of this.checks) {
      const list = groups.get(check.category) ?? [];
      list.push(check);
      groups.set(check.category, list);
    }

    const order = ["tools", "engine_tools", "config", "environments"];
    const items: DoctorNode[] = [];
    for (const cat of order) {
      const catChecks = groups.get(cat);
      if (catChecks) {
        items.push(new CategoryItem(cat, catChecks));
      }
    }

    // Add engine builds section if there are builds
    if (this.builds.length > 0) {
      items.push(new BuildsCategoryItem(this.builds.length));
    }

    return items;
  }
}
