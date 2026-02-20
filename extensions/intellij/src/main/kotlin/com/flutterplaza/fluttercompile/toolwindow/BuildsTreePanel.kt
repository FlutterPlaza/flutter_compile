package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.cli.BuildEntry
import com.flutterplaza.fluttercompile.cli.EngineStatus
import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.icons.AllIcons
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project
import com.intellij.ui.ColoredTreeCellRenderer
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.ToolbarDecorator
import com.intellij.ui.treeStructure.Tree
import java.awt.BorderLayout
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel

class BuildsTreePanel(private val project: Project) {
    val component: JComponent

    private val rootNode = DefaultMutableTreeNode("Builds")
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = false
        cellRenderer = BuildsCellRenderer()
        emptyText.text = "No engine configured. Run: flutter_compile engine init"
    }

    init {
        val toolbarPanel = ToolbarDecorator.createDecorator(tree)
            .disableAddAction()
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction("Refresh", "Refresh engine status", AllIcons.Actions.Refresh) {
                override fun actionPerformed(e: AnActionEvent) = refresh()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .createPanel()

        component = JPanel(BorderLayout()).apply {
            add(toolbarPanel, BorderLayout.CENTER)
        }
    }

    fun refresh() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Loading engine status...") {
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
            treeModel.reload()
            return
        }

        // Engine path info row
        status.engine_path?.let {
            rootNode.add(DefaultMutableTreeNode(InfoRow("Engine", it, AllIcons.Nodes.Folder)))
        }

        // Source status
        val sourceLabel = if (status.source_exists == true) "OK" else "Not found"
        val sourceIcon = if (status.source_exists == true) AllIcons.RunConfigurations.TestPassed else AllIcons.RunConfigurations.TestFailed
        rootNode.add(DefaultMutableTreeNode(InfoRow("Source", sourceLabel, sourceIcon)))

        // Host CPU
        status.host_cpu?.let {
            rootNode.add(DefaultMutableTreeNode(InfoRow("Host CPU", it, AllIcons.General.Information)))
        }

        // Build entries
        status.builds?.forEach { build ->
            rootNode.add(DefaultMutableTreeNode(build))
        }

        treeModel.reload()
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
