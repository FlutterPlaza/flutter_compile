import * as vscode from "vscode";
import * as cli from "../cli";

class BuildsInfoItem extends vscode.TreeItem {
  constructor(label: string, description: string, icon: string) {
    super(label, vscode.TreeItemCollapsibleState.None);
    this.description = description;
    this.iconPath = new vscode.ThemeIcon(icon);
  }
}

class BuildEntryItem extends vscode.TreeItem {
  constructor(name: string, size: string) {
    super(name, vscode.TreeItemCollapsibleState.None);
    this.description = size;
    this.iconPath = new vscode.ThemeIcon("package");
  }
}

type BuildsNode = BuildsInfoItem | BuildEntryItem;

export class BuildsTreeProvider
  implements vscode.TreeDataProvider<BuildsNode>
{
  private _onDidChangeTreeData = new vscode.EventEmitter<
    BuildsNode | undefined | void
  >();
  readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

  refresh(): void {
    this._onDidChangeTreeData.fire();
  }

  getTreeItem(element: BuildsNode): vscode.TreeItem {
    return element;
  }

  async getChildren(): Promise<BuildsNode[]> {
    const status = await cli.getStatus();

    await vscode.commands.executeCommand(
      "setContext",
      "flutterCompile.noEngine",
      !status.configured
    );

    if (!status.configured) {
      return [];
    }

    const items: BuildsNode[] = [];

    if (status.engine_path) {
      items.push(
        new BuildsInfoItem("Engine", status.engine_path, "folder")
      );
    }

    if (status.source_exists !== undefined) {
      items.push(
        new BuildsInfoItem(
          "Source",
          status.source_exists ? "OK" : "Not found",
          status.source_exists ? "check" : "close"
        )
      );
    }

    if (status.host_cpu) {
      items.push(
        new BuildsInfoItem("Host CPU", status.host_cpu, "server")
      );
    }

    if (status.builds) {
      for (const build of status.builds) {
        items.push(new BuildEntryItem(build.name, build.size));
      }
    }

    return items;
  }
}
