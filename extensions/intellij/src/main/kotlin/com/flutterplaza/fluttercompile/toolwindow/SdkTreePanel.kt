package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
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

    private val rootNode = DefaultMutableTreeNode(Constants.ROOT_SDKS)
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = false
        cellRenderer = SdkCellRenderer()
        emptyText.text = Constants.EMPTY_SDKS_HINT
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
            .setAddActionName(Constants.ACTION_INSTALL_SDK)
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction(Constants.ACTION_REFRESH, Constants.DESC_REFRESH_SDKS, AllIcons.Actions.Refresh) {
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
            add(object : AnAction(Constants.ACTION_SET_AS_GLOBAL, Constants.DESC_SET_AS_GLOBAL, AllIcons.Actions.SetDefault) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { setGlobalSdk(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedSdk() != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            add(object : AnAction(Constants.ACTION_PIN_TO_PROJECT, Constants.DESC_PIN_TO_PROJECT, AllIcons.Actions.PinTab) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { pinSdkToProject(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedSdk() != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            add(object : AnAction(Constants.ACTION_OPEN_SDK_FOLDER, Constants.DESC_OPEN_SDK_FOLDER, AllIcons.Actions.MenuOpen) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedSdk()?.let { openSdkFolder(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedSdk() != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            addSeparator()
            add(object : AnAction(Constants.ACTION_REMOVE_SDK, Constants.DESC_REMOVE_SDK, AllIcons.Actions.GC) {
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
                        .createActionPopupMenu(Constants.POPUP_SDK_TREE, group)
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
            object : Task.Backgroundable(project, Constants.PROGRESS_LOADING_SDKS) {
                override fun run(indicator: ProgressIndicator) {
                    val backend = SdkBackendProvider.get()
                    val sdks = backend.listSdks(project.basePath)
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
                    val success = SdkBackendProvider.get().setGlobalSdk(sdk.version)
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
        val projectPath = project.basePath ?: return
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Pinning ${sdk.version} to project...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = SdkBackendProvider.get().pinToProject(sdk.version, projectPath)
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
            Messages.showErrorDialog(project, "SDK folder not found: ${sdk.path}", Constants.PLUGIN_NAME)
        }
    }

    private fun removeSdk(sdk: SdkEntry) {
        val result = Messages.showYesNoDialog(
            project,
            "Remove Flutter SDK ${sdk.version}?\n\nThis will delete the SDK from disk.",
            Constants.DIALOG_REMOVE_SDK,
            Messages.getWarningIcon(),
        )
        if (result != Messages.YES) return

        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Removing SDK ${sdk.version}...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = SdkBackendProvider.get().removeSdk(sdk.version)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            refresh()
                            onMutation?.invoke()
                        } else {
                            Messages.showErrorDialog(project, "Failed to remove SDK ${sdk.version}.", Constants.PLUGIN_NAME)
                        }
                    }
                }
            }
        )
    }

    private fun installSdk() {
        val version = Messages.showInputDialog(
            project,
            Constants.MSG_ENTER_SDK_VERSION,
            Constants.DIALOG_INSTALL_SDK,
            null,
        )
        if (version.isNullOrBlank()) return

        val trimmed = version.trim()
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Installing Flutter SDK $trimmed...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = SdkBackendProvider.get().installSdk(trimmed, indicator)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            Messages.showInfoMessage(project, "Flutter SDK $trimmed installed.", Constants.PLUGIN_NAME)
                            refresh()
                            onMutation?.invoke()
                        } else {
                            Messages.showErrorDialog(project, "Failed to install Flutter SDK $trimmed.", Constants.PLUGIN_NAME)
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
            if (sdk.global) markers.add(Constants.MARKER_GLOBAL)
            if (sdk.project) markers.add(Constants.MARKER_PROJECT)
            if (sdk.contributor) markers.add(Constants.MARKER_CONTRIBUTOR)
            if (markers.isNotEmpty()) {
                append("  ${markers.joinToString(", ")}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
            }
        }
    }
}
