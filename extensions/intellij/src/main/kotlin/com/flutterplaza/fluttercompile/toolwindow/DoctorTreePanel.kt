package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.cli.DoctorCheck
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
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel

class DoctorTreePanel(private val project: Project) {
    val component: JComponent

    private val rootNode = DefaultMutableTreeNode("Doctor")
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = true
        cellRenderer = DoctorCellRenderer()
        emptyText.text = "Click refresh to run doctor checks."
    }

    init {
        val toolbarPanel = ToolbarDecorator.createDecorator(tree)
            .disableAddAction()
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction("Refresh", "Run doctor checks", AllIcons.Actions.Refresh) {
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
            object : Task.Backgroundable(project, "Running doctor checks...") {
                override fun run(indicator: ProgressIndicator) {
                    val checks = FlutterCompileCli.runDoctorJson()
                    ApplicationManager.getApplication().invokeLater {
                        buildTree(checks)
                    }
                }
            }
        )
    }

    private fun buildTree(checks: List<DoctorCheck>) {
        rootNode.removeAllChildren()

        val categoryOrder = listOf("tools", "engine_tools", "config", "environments")
        val categoryLabels = mapOf(
            "tools" to "Required Tools",
            "engine_tools" to "Engine Tools",
            "config" to "Configuration",
            "environments" to "Environments",
        )

        val grouped = checks.groupBy { it.category }

        for (cat in categoryOrder) {
            val catChecks = grouped[cat] ?: continue
            val okCount = catChecks.count { it.status == "ok" }
            val total = catChecks.size
            val label = categoryLabels[cat] ?: cat
            val allOk = okCount == total

            val categoryNode = DefaultMutableTreeNode(CategoryInfo(label, okCount, total, allOk))
            for (check in catChecks) {
                categoryNode.add(DefaultMutableTreeNode(check))
            }
            rootNode.add(categoryNode)
        }

        treeModel.reload()
        for (i in 0 until tree.rowCount) tree.expandRow(i)
    }

    /** Data wrapper for category nodes in the tree. */
    data class CategoryInfo(
        val label: String,
        val okCount: Int,
        val total: Int,
        val allOk: Boolean,
    )

    /** Custom cell renderer for doctor tree nodes. */
    private class DoctorCellRenderer : ColoredTreeCellRenderer() {
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
                is CategoryInfo -> renderCategory(obj)
                is DoctorCheck -> renderCheck(obj)
            }
        }

        private fun renderCategory(info: CategoryInfo) {
            icon = if (info.allOk) AllIcons.RunConfigurations.TestPassed else AllIcons.RunConfigurations.TestFailed
            append(info.label, SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)
            append("  ${info.okCount}/${info.total} OK", SimpleTextAttributes.GRAYED_ATTRIBUTES)
        }

        private fun renderCheck(check: DoctorCheck) {
            icon = when (check.status) {
                "ok" -> AllIcons.RunConfigurations.TestPassed
                "missing", "not_found", "invalid", "error" -> AllIcons.RunConfigurations.TestFailed
                else -> AllIcons.RunConfigurations.TestTerminated
            }
            append(check.name, SimpleTextAttributes.REGULAR_ATTRIBUTES)

            val description = when (check.status) {
                "ok" -> check.path ?: "ok"
                "missing", "not_found" -> "not installed"
                "error" -> check.error ?: "error"
                "invalid" -> check.error ?: "invalid"
                "not_configured" -> "not configured"
                "missing_remotes" -> "missing remotes: ${check.missing_remotes?.joinToString(", ") ?: ""}"
                "not_git_repo" -> "not a git repo"
                else -> check.status
            }
            append("  $description", SimpleTextAttributes.GRAYED_ATTRIBUTES)
        }
    }
}
