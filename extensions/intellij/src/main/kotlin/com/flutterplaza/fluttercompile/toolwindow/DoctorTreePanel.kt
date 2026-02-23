package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.DoctorCheck
import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.icons.AllIcons
import com.intellij.ide.BrowserUtil
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.*
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project
import com.intellij.ui.ColoredTreeCellRenderer
import com.intellij.ui.SimpleTextAttributes
import com.intellij.ui.ToolbarDecorator
import com.intellij.ui.treeStructure.Tree
import org.jetbrains.plugins.terminal.TerminalToolWindowManager
import java.awt.BorderLayout
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel

class DoctorTreePanel(private val project: Project) {
    val component: JComponent

    private val rootNode = DefaultMutableTreeNode(Constants.ROOT_DOCTOR)
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = true
        cellRenderer = DoctorCellRenderer()
        emptyText.text = Constants.EMPTY_DOCTOR_HINT
    }

    init {
        setupPopupMenu()

        val toolbarPanel = ToolbarDecorator.createDecorator(tree)
            .disableAddAction()
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction(Constants.ACTION_REFRESH, Constants.DESC_REFRESH_DOCTOR, AllIcons.Actions.Refresh) {
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
            add(object : AnAction(Constants.ACTION_INSTALL_SETUP, Constants.DESC_INSTALL_SETUP, AllIcons.Actions.Install) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedCheck()?.let { handleDoctorAction(it) }
                }
                override fun update(e: AnActionEvent) {
                    val check = selectedCheck()
                    e.presentation.isEnabled = check != null && check.status != Constants.STATUS_OK
                    e.presentation.text = check?.let { actionLabel(it) } ?: Constants.ACTION_INSTALL_SETUP
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
                    if (node.userObject !is DoctorCheck) return
                    val popupMenu = ActionManager.getInstance()
                        .createActionPopupMenu(Constants.POPUP_DOCTOR_TREE, group)
                    popupMenu.component.show(tree, e.x, e.y)
                }
            }
        })
    }

    private fun selectedCheck(): DoctorCheck? {
        val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return null
        return node.userObject as? DoctorCheck
    }

    private fun actionLabel(check: DoctorCheck): String = when (check.name) {
        Constants.CHECK_NINJA -> Constants.DOCTOR_ACTION_NINJA
        Constants.CHECK_GCLIENT -> Constants.DOCTOR_ACTION_DEPOT_TOOLS
        Constants.CHECK_XCODE -> Constants.DOCTOR_ACTION_XCODE
        Constants.CHECK_PYTHON3 -> Constants.DOCTOR_ACTION_PYTHON
        Constants.CHECK_GIT -> Constants.DOCTOR_ACTION_GIT
        Constants.RC_FILE -> Constants.DOCTOR_ACTION_RC_FILE
        else -> when (check.category) {
            Constants.CAT_ENVIRONMENTS -> Constants.DOCTOR_ACTION_SET_UP
            else -> Constants.DOCTOR_ACTION_INSTALL
        }
    }

    private fun handleDoctorAction(check: DoctorCheck) {
        when (check.name) {
            Constants.CHECK_NINJA -> runBackgroundInstall(Constants.PROGRESS_INSTALLING_NINJA, "brew", "install", Constants.CHECK_NINJA)
            Constants.CHECK_XCODE -> runBackgroundInstall(Constants.PROGRESS_INSTALLING_XCODE_CLT, "xcode-select", "--install")
            Constants.CHECK_GCLIENT -> installDepotTools()
            Constants.CHECK_PYTHON3 -> BrowserUtil.browse(Constants.URL_PYTHON_DOWNLOADS)
            Constants.CHECK_GIT -> BrowserUtil.browse(Constants.URL_GIT_DOWNLOADS)
            Constants.RC_FILE -> createDefaultRcFile()
            else -> when (check.category) {
                Constants.CAT_ENVIRONMENTS -> openTerminalWithCommand(environmentInstallCommand(check.name))
                else -> notify(Constants.NOTIFY_NO_AUTO_ACTION, "Please install ${check.name} manually.", NotificationType.INFORMATION)
            }
        }
    }

    private fun environmentInstallCommand(name: String): String {
        val envName = when {
            name.startsWith(Constants.ENV_PREFIX_FLUTTER) -> Constants.ENV_NAME_FLUTTER
            name.startsWith(Constants.ENV_PREFIX_DEVTOOLS) -> Constants.ENV_NAME_DEVTOOLS
            name.startsWith(Constants.ENV_PREFIX_ENGINE) -> Constants.ENV_NAME_ENGINE
            else -> return "${Constants.CLI_NAME} install"
        }
        val ideFlag = if (envName == Constants.ENV_NAME_FLUTTER) " --ide intellij" else ""
        return "${FlutterCompileCli.resolvedCliPath()} install $envName$ideFlag"
    }

    private fun runBackgroundInstall(title: String, vararg command: String) {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, title) {
                override fun run(indicator: ProgressIndicator) {
                    try {
                        val cmd = GeneralCommandLine(*command)
                            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
                        val handler = CapturingProcessHandler(cmd)
                        val result = handler.runProcess(300_000)
                        ApplicationManager.getApplication().invokeLater {
                            if (result.exitCode == 0) {
                                notify("Installed", "${command.last()} installed successfully.", NotificationType.INFORMATION)
                                refresh()
                            } else {
                                notify("Installation failed", result.stderr.ifBlank { "Exit code ${result.exitCode}" }, NotificationType.ERROR)
                            }
                        }
                    } catch (e: Exception) {
                        ApplicationManager.getApplication().invokeLater {
                            notify("Installation failed", e.message ?: "Unknown error", NotificationType.ERROR)
                        }
                    }
                }
            }
        )
    }

    private fun installDepotTools() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, Constants.PROGRESS_INSTALLING_DEPOT_TOOLS) {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.installDepotTools()
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            notify(
                                Constants.NOTIFY_DEPOT_TOOLS_INSTALLED,
                                "Installed at ${FlutterCompileCli.depotToolsPath()} and added to PATH. Restart your terminal to apply.",
                                NotificationType.INFORMATION,
                            )
                            refresh()
                        } else {
                            notify(Constants.NOTIFY_INSTALL_FAILED, "Failed to clone depot_tools.", NotificationType.ERROR)
                        }
                    }
                }
            }
        )
    }

    private fun createDefaultRcFile() {
        val home = System.getProperty(Constants.SYS_USER_HOME)
        val rcFile = java.io.File(home, Constants.RC_FILE)
        if (rcFile.exists()) {
            notify(Constants.NOTIFY_CONFIG_EXISTS, "${Constants.RC_FILE} already exists at ${rcFile.absolutePath}", NotificationType.INFORMATION)
            refresh()
            return
        }
        try {
            rcFile.writeText(Constants.RC_FILE_DEFAULT_CONTENT)
            notify(Constants.NOTIFY_CONFIG_CREATED, "Created ${rcFile.absolutePath}", NotificationType.INFORMATION)
            refresh()
        } catch (e: Exception) {
            notify(Constants.NOTIFY_CONFIG_FAILED, e.message ?: Constants.MSG_UNKNOWN_ERROR, NotificationType.ERROR)
        }
    }

    private fun openTerminalWithCommand(command: String) {
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_FLUTTER_COMPILE)
            widget.executeCommand(command)
        } catch (e: Exception) {
            notify(Constants.NOTIFY_TERMINAL_ERROR, "Could not open terminal: ${e.message}", NotificationType.ERROR)
        }
    }

    private fun notify(title: String, content: String, type: NotificationType) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup(Constants.NOTIFICATION_GROUP)
            .createNotification(title, content, type)
            .notify(project)
    }

    fun refresh() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, Constants.PROGRESS_RUNNING_DOCTOR) {
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

        if (checks.isEmpty()) {
            tree.emptyText.clear()
            tree.emptyText.appendText(
                Constants.EMPTY_DOCTOR_CLI_MISSING,
                SimpleTextAttributes.REGULAR_ATTRIBUTES,
            )
            tree.emptyText.appendLine(
                Constants.EMPTY_DOCTOR_INSTALL_LINK,
                SimpleTextAttributes.LINK_ATTRIBUTES,
            ) { installCli() }
            treeModel.reload()
            return
        }

        val categoryOrder = listOf(Constants.CAT_TOOLS, Constants.CAT_ENGINE_TOOLS, Constants.CAT_CONFIG, Constants.CAT_ENVIRONMENTS)
        val categoryLabels = mapOf(
            Constants.CAT_TOOLS to Constants.LABEL_REQUIRED_TOOLS,
            Constants.CAT_ENGINE_TOOLS to Constants.LABEL_ENGINE_TOOLS,
            Constants.CAT_CONFIG to Constants.LABEL_CONFIGURATION,
            Constants.CAT_ENVIRONMENTS to Constants.LABEL_ENVIRONMENTS,
        )

        val grouped = checks.groupBy { it.category }

        for (cat in categoryOrder) {
            val catChecks = grouped[cat] ?: continue
            val okCount = catChecks.count { it.status == Constants.STATUS_OK }
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

    private fun installCli() {
        val dartPath = FlutterCompileCli.findDartExecutable()
        if (dartPath == null) {
            notify(
                Constants.NOTIFY_DART_NOT_FOUND,
                Constants.MSG_INSTALL_MANUALLY,
                NotificationType.ERROR,
            )
            return
        }

        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, Constants.PROGRESS_INSTALLING_CLI) {
                override fun run(indicator: ProgressIndicator) {
                    try {
                        val cmd = GeneralCommandLine(dartPath, "pub", "global", "activate", Constants.CLI_PACKAGE_NAME)
                            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
                        val handler = CapturingProcessHandler(cmd)
                        val result = handler.runProcess(120_000)

                        ApplicationManager.getApplication().invokeLater {
                            if (result.exitCode == 0) {
                                FlutterCompileCli.invalidateResolvedPath()
                                notify(Constants.NOTIFY_CLI_INSTALLED, Constants.MSG_CLI_ACTIVATED, NotificationType.INFORMATION)
                                refresh()
                            } else {
                                notify(
                                    Constants.NOTIFY_INSTALL_FAILED,
                                    result.stderr.ifBlank { "dart pub global activate ${Constants.CLI_PACKAGE_NAME} exited with code ${result.exitCode}" },
                                    NotificationType.ERROR,
                                )
                            }
                        }
                    } catch (e: Exception) {
                        ApplicationManager.getApplication().invokeLater {
                            notify(Constants.NOTIFY_INSTALL_FAILED, e.message ?: Constants.MSG_UNKNOWN_ERROR, NotificationType.ERROR)
                        }
                    }
                }
            }
        )
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
                Constants.STATUS_OK -> AllIcons.RunConfigurations.TestPassed
                Constants.STATUS_MISSING, Constants.STATUS_NOT_FOUND, Constants.STATUS_INVALID, Constants.STATUS_ERROR -> AllIcons.RunConfigurations.TestFailed
                else -> AllIcons.RunConfigurations.TestTerminated
            }
            append(check.name, SimpleTextAttributes.REGULAR_ATTRIBUTES)

            val description = when (check.status) {
                Constants.STATUS_OK -> check.path ?: Constants.STATUS_OK
                Constants.STATUS_MISSING, Constants.STATUS_NOT_FOUND -> Constants.DESC_NOT_INSTALLED
                Constants.STATUS_ERROR -> check.error ?: Constants.STATUS_ERROR
                Constants.STATUS_INVALID -> check.error ?: Constants.STATUS_INVALID
                Constants.STATUS_NOT_CONFIGURED -> Constants.DESC_NOT_CONFIGURED
                Constants.STATUS_MISSING_REMOTES -> "missing remotes: ${check.missing_remotes?.joinToString(", ") ?: ""}"
                Constants.STATUS_NOT_GIT_REPO -> Constants.DESC_NOT_GIT_REPO
                else -> check.status
            }
            append("  $description", SimpleTextAttributes.GRAYED_ATTRIBUTES)
        }
    }
}
