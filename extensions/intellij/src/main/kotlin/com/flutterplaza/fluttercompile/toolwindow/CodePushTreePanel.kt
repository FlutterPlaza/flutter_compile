package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.CodePushAccount
import com.flutterplaza.fluttercompile.cli.CodePushAppStatus
import com.flutterplaza.fluttercompile.cli.CodePushPatch
import com.flutterplaza.fluttercompile.cli.CodePushPatchesResponse
import com.flutterplaza.fluttercompile.cli.CodePushRelease
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
import javax.swing.Icon
import javax.swing.JComponent
import javax.swing.JPanel
import javax.swing.tree.DefaultMutableTreeNode
import javax.swing.tree.DefaultTreeModel

class CodePushTreePanel(private val project: Project) {
    val component: JComponent

    private val rootNode = DefaultMutableTreeNode(Constants.ROOT_CODE_PUSH)
    private val treeModel = DefaultTreeModel(rootNode)
    private val tree = Tree(treeModel).apply {
        isRootVisible = false
        showsRootHandles = true
        cellRenderer = CodePushCellRenderer()
        emptyText.text = Constants.EMPTY_CODE_PUSH_HINT
    }

    init {
        val toolbarPanel = ToolbarDecorator.createDecorator(tree)
            .disableAddAction()
            .disableRemoveAction()
            .disableUpDownActions()
            .addExtraAction(object : AnAction(Constants.ACTION_REFRESH, Constants.DESC_REFRESH, AllIcons.Actions.Refresh) {
                override fun actionPerformed(e: AnActionEvent) = refresh()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .addExtraAction(object : AnAction("Login", "Login to Code Push", AllIcons.Actions.Execute) {
                override fun actionPerformed(e: AnActionEvent) = codePushLogin()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .addExtraAction(object : AnAction("Create Release", "Create a Code Push release", AllIcons.Actions.Compile) {
                override fun actionPerformed(e: AnActionEvent) = codePushRelease()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .addExtraAction(object : AnAction("Create Patch", "Create a Code Push patch", AllIcons.Actions.Diff) {
                override fun actionPerformed(e: AnActionEvent) = codePushPatch()
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT
            })
            .createPanel()

        component = JPanel(BorderLayout()).apply {
            add(toolbarPanel, BorderLayout.CENTER)
        }
    }

    fun refresh() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, Constants.PROGRESS_LOADING_CODE_PUSH) {
                override fun run(indicator: ProgressIndicator) {
                    val account = FlutterCompileCli.codePushAccount()
                    val appStatus = FlutterCompileCli.codePushStatus()

                    val patchesByRelease = mutableMapOf<String, CodePushPatchesResponse>()
                    appStatus.releases?.forEach { release ->
                        patchesByRelease[release.id] = FlutterCompileCli.codePushPatches(release.id)
                    }

                    ApplicationManager.getApplication().invokeLater {
                        buildTree(account, appStatus, patchesByRelease)
                    }
                }
            }
        )
    }

    private fun buildTree(
        account: CodePushAccount,
        appStatus: CodePushAppStatus,
        patchesByRelease: Map<String, CodePushPatchesResponse>,
    ) {
        rootNode.removeAllChildren()

        if (!account.logged_in) {
            tree.emptyText.clear()
            tree.emptyText.appendText(Constants.CODE_PUSH_NOT_LOGGED_IN, SimpleTextAttributes.REGULAR_ATTRIBUTES)
            tree.emptyText.appendLine(
                "Login",
                SimpleTextAttributes.LINK_ATTRIBUTES,
            ) { codePushLogin() }
            treeModel.reload()
            return
        }

        // Account section
        val accountNode = DefaultMutableTreeNode(
            InfoRow("Account", account.email ?: "unknown", AllIcons.General.User)
        )
        account.tier?.let {
            accountNode.add(DefaultMutableTreeNode(InfoRow("Tier", it, AllIcons.General.Information)))
        }
        rootNode.add(accountNode)

        if (!appStatus.configured) {
            rootNode.add(DefaultMutableTreeNode(
                InfoRow("App", Constants.CODE_PUSH_NO_APP, AllIcons.General.Warning)
            ))
            treeModel.reload()
            for (i in 0 until tree.rowCount) tree.expandRow(i)
            return
        }

        // App section
        val appNode = DefaultMutableTreeNode(
            InfoRow("App", appStatus.app_name ?: "unknown", AllIcons.Nodes.Module)
        )
        appStatus.app_id?.let {
            appNode.add(DefaultMutableTreeNode(InfoRow("ID", it, AllIcons.General.Information)))
        }
        rootNode.add(appNode)

        // Releases section
        val releases = appStatus.releases
        if (releases.isNullOrEmpty()) {
            rootNode.add(DefaultMutableTreeNode(
                InfoRow("Releases", "No releases yet", AllIcons.General.Information)
            ))
        } else {
            val releasesNode = DefaultMutableTreeNode(
                InfoRow("Releases", "${releases.size} release(s)", AllIcons.Nodes.Deploy)
            )
            for (release in releases) {
                val releaseNode = DefaultMutableTreeNode(ReleaseRow(release))
                val patchesResponse = patchesByRelease[release.id]
                val patches = patchesResponse?.patches
                if (patches.isNullOrEmpty()) {
                    releaseNode.add(DefaultMutableTreeNode(
                        InfoRow("Patches", "No patches", AllIcons.General.Information)
                    ))
                } else {
                    for (patch in patches) {
                        releaseNode.add(DefaultMutableTreeNode(PatchRow(patch)))
                    }
                }
                releasesNode.add(releaseNode)
            }
            rootNode.add(releasesNode)
        }

        treeModel.reload()
        for (i in 0 until tree.rowCount) tree.expandRow(i)
    }

    private fun codePushLogin() {
        val apiKey = Messages.showInputDialog(
            project,
            "Enter your Code Push API key:",
            "Code Push Login",
            null,
        )
        if (apiKey.isNullOrBlank()) return

        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath codepush login --api-key $apiKey"
        openTerminalWithCommand(command)
    }

    private fun codePushRelease() {
        val platforms = arrayOf("apk", "ios", "linux", "macos", "windows")
        val platform = Messages.showEditableChooseDialog(
            "Select target platform:",
            "Code Push Release",
            null,
            platforms,
            platforms[0],
            null,
        ) ?: return

        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath codepush release --build --platform $platform"
        openTerminalWithCommand(command)
    }

    private fun codePushPatch() {
        val rollout = Messages.showInputDialog(
            project,
            "Rollout percentage (1-100):",
            "Code Push Patch",
            null,
            "100",
            null,
        ) ?: return

        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath codepush patch --build --rollout $rollout"
        openTerminalWithCommand(command)
    }

    private fun openTerminalWithCommand(command: String) {
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_CODE_PUSH)
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

    /** Data wrapper for info rows in the tree. */
    data class InfoRow(val label: String, val value: String, val icon: Icon)

    /** Data wrapper for release rows in the tree. */
    data class ReleaseRow(val release: CodePushRelease)

    /** Data wrapper for patch rows in the tree. */
    data class PatchRow(val patch: CodePushPatch)

    /** Custom cell renderer for Code Push tree nodes. */
    private class CodePushCellRenderer : ColoredTreeCellRenderer() {
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
                is ReleaseRow -> {
                    icon = AllIcons.Nodes.Artifact
                    append(obj.release.version, SimpleTextAttributes.REGULAR_ATTRIBUTES)
                    val markers = mutableListOf<String>()
                    obj.release.platform?.let { markers.add(it) }
                    obj.release.created_at?.let { markers.add(it) }
                    if (markers.isNotEmpty()) {
                        append("  ${markers.joinToString(" \u2022 ")}", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    }
                }
                is PatchRow -> {
                    val patch = obj.patch
                    icon = if (patch.active) AllIcons.RunConfigurations.TestPassed else AllIcons.RunConfigurations.TestFailed
                    append("Patch #${patch.number}", SimpleTextAttributes.REGULAR_ATTRIBUTES)
                    val status = if (patch.active) "active" else "inactive"
                    append("  ${patch.rollout}% rollout, $status", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    patch.created_at?.let {
                        append("  \u2022 $it", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    }
                }
            }
        }
    }
}
