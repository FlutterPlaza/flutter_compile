package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.flutterplaza.fluttercompile.settings.SdkPathUpdater
import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.*
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project
import com.intellij.openapi.ui.Messages
import com.intellij.ui.ColoredTreeCellRenderer
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.ToolbarDecorator
import com.intellij.ui.treeStructure.Tree
import com.intellij.ide.actions.RevealFileAction
import java.awt.BorderLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.io.File
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel

class SdkTreePanel(private val project: Project) {
    val component: JComponent

    private val rootNode = DefaultMutableTreeNode("SDKs")
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = false
        cellRenderer = SdkCellRenderer()
        emptyText.text = "No SDKs installed. Click + to install."
    }

    var onMutation: (() -> Unit)? = null

    init {
        tree.addMouseListener(object : MouseAdapter() {
            override fun mouseClicked(e: MouseEvent) {
                if (e.clickCount == 2) {
                    val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return
                    val sdk = node.userObject as? SdkEntry ?: return
                    setGlobalSdk(sdk)
                }
            }
        })

        setupPopupMenu()

        val toolbarPanel = ToolbarDecorator.createDecorator(tree)
            .setAddAction { installSdk() }
            .setAddActionName("Install SDK")
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction("Refresh", "Refresh SDK list", AllIcons.Actions.Refresh) {
                override fun actionPerformed(e: AnActionEvent) = refresh()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .createPanel()

        component = JPanel(BorderLayout()).apply {
            add(toolbarPanel, BorderLayout.CENTER)
        }
    }

    private fun setupPopupMenu() {
        val group = DefaultActionGroup().apply {
            add(object : AnAction("Set as Global", "Set this SDK as the global default", AllIcons.Actions.SetDefault) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { setGlobalSdk(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedSdk() != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            add(object : AnAction("Pin to Project", "Pin this SDK to the current project", AllIcons.Actions.PinTab) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { pinSdkToProject(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedSdk() != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            add(object : AnAction("Open SDK Folder", "Reveal SDK folder in file manager", AllIcons.Actions.MenuOpen) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { openSdkFolder(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedSdk() != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            addSeparator()
            add(object : AnAction("Remove SDK", "Remove this SDK installation", AllIcons.Actions.GC) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { removeSdk(it) }
                }
                override fun update(e: AnActionEvent) {
                    val sdk = selectedSdk()
                    e.presentation.isEnabled = sdk != null && !sdk.contributor
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
        }

        tree.addMouseListener(object : MouseAdapter() {
            override fun mousePressed(e: MouseEvent) = maybeShowPopup(e)
            override fun mouseReleased(e: MouseEvent) = maybeShowPopup(e)
            private fun maybeShowPopup(e: MouseEvent) {
                if (e.isPopupTrigger) {
                    val path = tree.getPathForLocation(e.x, e.y) ?: return
                    tree.selectionPath = path
                    val popupMenu = ActionManager.getInstance()
                        .createActionPopupMenu("FlutterCompile.SdkTree", group)
                    popupMenu.component.show(tree, e.x, e.y)
                }
            }
        })
    }

    private fun selectedSdk(): SdkEntry? {
        val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return null
        return node.userObject as? SdkEntry
    }

    fun refresh() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Loading SDKs...") {
                override fun run(indicator: ProgressIndicator) {
                    val sdks = FlutterCompileCli.listSdks()
                    ApplicationManager.getApplication().invokeLater {
                        rootNode.removeAllChildren()
                        sdks.forEach { rootNode.add(DefaultMutableTreeNode(it)) }
                        treeModel.reload()
                        for (i in 0 until tree.rowCount) tree.expandRow(i)
                    }
                }
            }
        )
    }

    private fun setGlobalSdk(sdk: SdkEntry) {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Setting global SDK to ${sdk.version}...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.setGlobalSdk(sdk.version)
                    if (success) {
                        ApplicationManager.getApplication().invokeLater {
                            SdkPathUpdater.updateFlutterSdkPath(project, sdk.version)
                            refresh()
                            onMutation?.invoke()
                        }
                    }
                }
            }
        )
    }

    private fun pinSdkToProject(sdk: SdkEntry) {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Pinning ${sdk.version} to project...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.useSdk(sdk.version)
                    if (success) {
                        ApplicationManager.getApplication().invokeLater {
                            SdkPathUpdater.updateFlutterSdkPath(project, sdk.version)
                            refresh()
                            onMutation?.invoke()
                        }
                    }
                }
            }
        )
    }

    private fun openSdkFolder(sdk: SdkEntry) {
        val file = File(sdk.path)
        if (file.exists()) {
            RevealFileAction.openDirectory(file)
        } else {
            Messages.showErrorDialog(project, "SDK folder not found: ${sdk.path}", "Flutter Compile")
        }
    }

    private fun removeSdk(sdk: SdkEntry) {
        val result = Messages.showYesNoDialog(
            project,
            "Remove Flutter SDK ${sdk.version}?\n\nThis will delete the SDK from disk.",
            "Remove SDK",
            Messages.getWarningIcon(),
        )
        if (result != Messages.YES) return

        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Removing SDK ${sdk.version}...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.removeSdk(sdk.version)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            refresh()
                            onMutation?.invoke()
                        } else {
                            Messages.showErrorDialog(project, "Failed to remove SDK ${sdk.version}.", "Flutter Compile")
                        }
                    }
                }
            }
        )
    }

    private fun installSdk() {
        val version = Messages.showInputDialog(
            project,
            "Enter Flutter SDK version or channel to install:",
            "Install Flutter SDK",
            null,
        )
        if (version.isNullOrBlank()) return

        val trimmed = version.trim()
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Installing Flutter SDK $trimmed...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.installSdk(trimmed)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            Messages.showInfoMessage(project, "Flutter SDK $trimmed installed.", "Flutter Compile")
                            refresh()
                            onMutation?.invoke()
                        } else {
                            Messages.showErrorDialog(project, "Failed to install Flutter SDK $trimmed.", "Flutter Compile")
                        }
                    }
                }
            }
        )
    }

    /** Custom cell renderer for SDK tree nodes. */
    private class SdkCellRenderer : ColoredTreeCellRenderer() {
        override fun customizeCellRenderer(
            tree: javax.swing.JTree,
            value: Any?,
            selected: Boolean,
            expanded: Boolean,
            leaf: Boolean,
            row: Int,
            hasFocus: Boolean,
        ) {
            val node = value as? DefaultMutableTreeNode ?: return
            val sdk = node.userObject as? SdkEntry ?: return

            icon = when {
                sdk.contributor -> AllIcons.Nodes.Plugin
                sdk.global || sdk.project -> AllIcons.RunConfigurations.TestPassed
                else -> AllIcons.Nodes.PpLib
            }

            append(sdk.version, SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)

            val markers = mutableListOf<String>()
            if (sdk.global) markers.add("global")
            if (sdk.project) markers.add("project")
            if (sdk.contributor) markers.add("contributor")
            if (markers.isNotEmpty()) {
                append("  ${markers.joinToString(", ")}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
            }
        }
    }
}
