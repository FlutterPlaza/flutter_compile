import * as vscode from "vscode";
import type { SdkEntry } from "../cli";
import * as cli from "../cli";

export class SdkTreeItem extends vscode.TreeItem {
  constructor(public readonly sdk: SdkEntry) {
    super(sdk.version, vscode.TreeItemCollapsibleState.None);

    const markers: string[] = [];
    if (sdk.global) {
      markers.push("global");
    }
    if (sdk.project) {
      markers.push("project");
    }
    this.description = markers.join(", ");

    if (sdk.contributor) {
      this.iconPath = new vscode.ThemeIcon("beaker");
      this.contextValue = "sdkContributor";
    } else if (sdk.global || sdk.project) {
      this.iconPath = new vscode.ThemeIcon(
        "check",
        new vscode.ThemeColor("charts.green")
      );
      this.contextValue = "sdk";
    } else {
      this.iconPath = new vscode.ThemeIcon("package");
      this.contextValue = "sdk";
    }

    const lines = [`**${sdk.version}**`, `Path: \`${sdk.path}\``];
    if (markers.length > 0) {
      lines.push(`Status: ${markers.join(", ")}`);
    }
    if (sdk.contributor) {
      lines.push("Type: contributor (locally compiled)");
    }
    this.tooltip = new vscode.MarkdownString(lines.join("\n\n"));
  }
}

export class SdkTreeProvider
  implements vscode.TreeDataProvider<SdkTreeItem>
{
  private _onDidChangeTreeData = new vscode.EventEmitter<
    SdkTreeItem | undefined | void
  >();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  refresh(): void {
    this._onDidChangeTreeData.fire();
  }

  getTreeItem(element: SdkTreeItem): vscode.TreeItem {
    return element;
  }

  async getChildren(): Promise<SdkTreeItem[]> {
    const sdks = await cli.listSdks();
    await vscode.commands.executeCommand(
      "setContext",
      "flutterCompile.noSdks",
      sdks.length === 0
    );
    return sdks.map((sdk) => new SdkTreeItem(sdk));
  }
}
