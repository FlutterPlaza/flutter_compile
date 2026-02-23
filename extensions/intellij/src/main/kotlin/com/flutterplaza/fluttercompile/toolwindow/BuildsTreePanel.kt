package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.BuildEntry
import com.flutterplaza.fluttercompile.cli.EngineStatus
import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.icons.AllIcons
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
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
import org.jetbrains.plugins.terminal.TerminalToolWindowManager
import java.awt.BorderLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel

class BuildsTreePanel(private val project: Project) {
    val component: JComponent

    private val rootNode = DefaultMutableTreeNode(Constants.ROOT_BUILDS)
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = false
        cellRenderer = BuildsCellRenderer()
        emptyText.text = Constants.EMPTY_BUILDS_HINT
    }

    init {
        setupPopupMenu()

        val toolbarPanel = ToolbarDecorator.createDecorator(tree)
            .disableAddAction()
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction(Constants.ACTION_BUILD_ENGINE, Constants.DESC_BUILD_ENGINE, AllIcons.Actions.Compile) {
                override fun actionPerformed(e: AnActionEvent) = buildEngine()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .addExtraAction(object : AnAction(Constants.ACTION_INIT_ENGINE, Constants.DESC_INIT_ENGINE, AllIcons.Actions.Execute) {
                override fun actionPerformed(e: AnActionEvent) = initEngine()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .addExtraAction(object : AnAction(Constants.ACTION_REFRESH, Constants.DESC_REFRESH, AllIcons.Actions.Refresh) {
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
            add(object : AnAction(Constants.ACTION_DELETE_BUILD, Constants.DESC_DELETE_BUILD, AllIcons.Actions.GC) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedBuild()?.let { deleteBuild(it) }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabled = selectedBuild() != null
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
                    val node = path.lastPathComponent as? DefaultMutableTreeNode ?: return
                    if (node.userObject !is BuildEntry) return
                    val popupMenu = ActionManager.getInstance()
                        .createActionPopupMenu(Constants.POPUP_BUILDS_TREE, group)
                    popupMenu.component.show(tree, e.x, e.y)
                }
            }
        })
    }

    private fun selectedBuild(): BuildEntry? {
        val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return null
        return node.userObject as? BuildEntry
    }

    private fun deleteBuild(build: BuildEntry) {
        val result = Messages.showYesNoDialog(
            project,
            "Delete engine build \"${build.name}\" (${build.size})?\n\nThis will permanently remove the build output from disk.",
            Constants.DIALOG_DELETE_BUILD,
            Messages.getWarningIcon(),
        )
        if (result != Messages.YES) return

        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Deleting build ${build.name}...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.cleanBuild(build.name)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            refresh()
                        } else {
                            Messages.showErrorDialog(
                                project,
                                "Failed to delete build \"${build.name}\".",
                                Constants.PLUGIN_NAME,
                            )
                        }
                    }
                }
            }
        )
    }

    fun refresh() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, Constants.PROGRESS_LOADING_ENGINE) {
                override fun run(indicator: ProgressIndicator) {
                    val status = FlutterCompileCli.getStatus()
                    ApplicationManager.getApplication().invokeLater {
                        buildTree(status)
                    }
                }
            }
        )
    }

    private fun buildTree(status: EngineStatus) {
        rootNode.removeAllChildren()

        if (!status.configured) {
            tree.emptyText.clear()
            tree.emptyText.appendText(Constants.EMPTY_BUILDS_HINT, SimpleTextAttributes.REGULAR_ATTRIBUTES)
            tree.emptyText.appendLine(
                Constants.EMPTY_BUILDS_INIT_LINK,
                SimpleTextAttributes.LINK_ATTRIBUTES,
            ) { initEngine() }
            treeModel.reload()
            return
        }

        // Engine path info row
        status.engine_path?.let {
            rootNode.add(DefaultMutableTreeNode(InfoRow(Constants.BUILD_LABEL_ENGINE, it, AllIcons.Nodes.Folder)))
        }

        // Source status
        val sourceLabel = if (status.source_exists == true) Constants.BUILD_SOURCE_OK else Constants.BUILD_SOURCE_NOT_FOUND
        val sourceIcon = if (status.source_exists == true) AllIcons.RunConfigurations.TestPassed else AllIcons.RunConfigurations.TestFailed
        rootNode.add(DefaultMutableTreeNode(InfoRow(Constants.BUILD_LABEL_SOURCE, sourceLabel, sourceIcon)))

        // Host CPU
        status.host_cpu?.let {
            rootNode.add(DefaultMutableTreeNode(InfoRow(Constants.BUILD_LABEL_HOST_CPU, it, AllIcons.General.Information)))
        }

        // Build entries
        status.builds?.forEach { build ->
            rootNode.add(DefaultMutableTreeNode(build))
        }

        treeModel.reload()
    }

    private fun initEngine() {
        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath install ${Constants.ENV_NAME_ENGINE}"
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_FLUTTER_COMPILE)
            widget.executeCommand(command)
        } catch (e: Exception) {
            NotificationGroupManager.getInstance()
                .getNotificationGroup(Constants.NOTIFICATION_GROUP)
                .createNotification(
                    Constants.NOTIFY_TERMINAL_ERROR,
                    "Could not open terminal. Run manually: $command",
                    NotificationType.ERROR,
                )
                .notify(project)
        }
    }

    private fun buildEngine() {
        val cliPath = FlutterCompileCli.resolvedCliPath()

        val platformCombo = javax.swing.JComboBox(Constants.BUILD_PLATFORMS)
        val modeCombo = javax.swing.JComboBox(Constants.BUILD_MODES)
        val unoptimizedCheck = javax.swing.JCheckBox(Constants.BUILD_CHECKBOX_UNOPT, true)
        val cleanCheck = javax.swing.JCheckBox(Constants.BUILD_CHECKBOX_CLEAN, false)
        val forceGnCheck = javax.swing.JCheckBox(Constants.BUILD_CHECKBOX_FORCE_GN, false)

        val panel = JPanel(java.awt.GridLayout(0, 2, 8, 4)).apply {
            add(javax.swing.JLabel(Constants.LABEL_PLATFORM))
            add(platformCombo)
            add(javax.swing.JLabel(Constants.LABEL_BUILD_MODE))
            add(modeCombo)
            add(unoptimizedCheck)
            add(cleanCheck)
            add(forceGnCheck)
            add(javax.swing.JLabel()) // spacer
        }

        val result = javax.swing.JOptionPane.showConfirmDialog(
            component, panel, Constants.DIALOG_BUILD_ENGINE, javax.swing.JOptionPane.OK_CANCEL_OPTION, javax.swing.JOptionPane.PLAIN_MESSAGE
        )
        if (result != javax.swing.JOptionPane.OK_OPTION) return

        val platform = platformCombo.selectedItem as String
        val mode = modeCombo.selectedItem as String
        val args = mutableListOf("build", Constants.ENV_NAME_ENGINE, "-p", platform, "-m", mode)
        if (unoptimizedCheck.isSelected) args.add("--unoptimized")
        if (!unoptimizedCheck.isSelected) args.add("--no-unoptimized")
        if (cleanCheck.isSelected) args.add("--clean")
        if (forceGnCheck.isSelected) args.add("--gn")

        val command = "$cliPath ${args.joinToString(" ")}"
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_ENGINE_BUILD)
            widget.executeCommand(command)
        } catch (e: Exception) {
            NotificationGroupManager.getInstance()
                .getNotificationGroup(Constants.NOTIFICATION_GROUP)
                .createNotification(
                    Constants.NOTIFY_TERMINAL_ERROR,
                    "Could not open terminal. Run manually: $command",
                    NotificationType.ERROR,
                )
                .notify(project)
        }
    }

    /** Data wrapper for info rows in the tree (non-build entries). */
    data class InfoRow(val label: String, val value: String, val icon: Icon)

    /** Custom cell renderer for builds tree nodes. */
    private class BuildsCellRenderer : ColoredTreeCellRenderer() {
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
            when (val obj = node.userObject) {
                is InfoRow -> {
                    icon = obj.icon
                    append(obj.label, SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)
                    append("  ${obj.value}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
                is BuildEntry -> {
                    icon = AllIcons.Nodes.PpLib
                    append(obj.name, SimpleTextAttributes.REGULAR_ATTRIBUTES)
                    append("  ${obj.size}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                }
            }
        }
    }
}
