package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.CodePushAccount
import com.flutterplaza.fluttercompile.cli.CodePushAppStatus
import com.flutterplaza.fluttercompile.cli.CodePushPatch
import com.flutterplaza.fluttercompile.cli.CodePushPatchesResponse
import com.flutterplaza.fluttercompile.cli.CodePushRelease
import com.flutterplaza.fluttercompile.cli.CodePushVersionEntry
import com.flutterplaza.fluttercompile.cli.CodePushVersionsResponse
import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.flutterplaza.fluttercompile.settings.SdkPathUpdater
import com.intellij.icons.AllIcons
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.*
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.ide.CopyPasteManager
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
import java.awt.datatransfer.StringSelection
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
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

    private val loginPollExecutor = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "flutter-compile-codepush-login-poll").apply { isDaemon = true }
    }

    init {
        setupPopupMenu()

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
                    val versions = FlutterCompileCli.codePushVersions()
                    val account = FlutterCompileCli.codePushAccount()
                    val appStatus = FlutterCompileCli.codePushStatus()

                    val patchesByRelease = mutableMapOf<String, CodePushPatchesResponse>()
                    appStatus.releases?.forEach { release ->
                        patchesByRelease[release.id] = FlutterCompileCli.codePushPatches(release.id)
                    }

                    ApplicationManager.getApplication().invokeLater {
                        buildTree(versions, account, appStatus, patchesByRelease)
                    }
                }
            }
        )
    }

    private fun buildTree(
        versions: CodePushVersionsResponse,
        account: CodePushAccount,
        appStatus: CodePushAppStatus,
        patchesByRelease: Map<String, CodePushPatchesResponse>,
    ) {
        rootNode.removeAllChildren()

        // Supported Flutter Versions — always at the top, even when not logged in.
        val versionsList = versions.versions ?: emptyList()
        val versionsHeaderValue = when {
            versions.error != null -> "unavailable"
            else -> "${versionsList.size} available"
        }
        val versionsNode = DefaultMutableTreeNode(
            InfoRow("Supported Flutter Versions", versionsHeaderValue, AllIcons.Actions.Refresh)
        )
        if (versions.error != null) {
            versionsNode.add(DefaultMutableTreeNode(
                InfoRow("Failed to load versions", versions.error, AllIcons.General.Warning)
            ))
        } else if (versionsList.isEmpty()) {
            versionsNode.add(DefaultMutableTreeNode(
                InfoRow("None", "Check your code push server connection", AllIcons.General.Warning)
            ))
        } else {
            for (v in versionsList) {
                versionsNode.add(DefaultMutableTreeNode(
                    VersionRow(v, isSelected = versions.selected == v.version)
                ))
            }
        }
        rootNode.add(versionsNode)

        if (!account.logged_in) {
            val notLoggedNode = DefaultMutableTreeNode(
                InfoRow("Account", "not logged in", AllIcons.General.Warning)
            )
            rootNode.add(notLoggedNode)
            tree.emptyText.clear()
            tree.emptyText.appendText(Constants.CODE_PUSH_NOT_LOGGED_IN, SimpleTextAttributes.REGULAR_ATTRIBUTES)
            tree.emptyText.appendLine(
                "Login",
                SimpleTextAttributes.LINK_ATTRIBUTES,
            ) { codePushLogin() }
            treeModel.reload()
            for (i in 0 until tree.rowCount) tree.expandRow(i)
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
            val noAppNode = DefaultMutableTreeNode(
                InfoRow("App", Constants.CODE_PUSH_NO_APP, AllIcons.General.Warning)
            )
            noAppNode.add(DefaultMutableTreeNode(InitAppLink))
            rootNode.add(noAppNode)
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

        // Patches summary row
        val totalPatches = appStatus.total_patches.takeIf { it > 0 }
            ?: patchesByRelease.values.sumOf { it.patches?.size ?: 0 }
        val releaseCount = appStatus.releases?.size ?: 0
        rootNode.add(DefaultMutableTreeNode(
            InfoRow("Patches", "$totalPatches across $releaseCount release(s)", AllIcons.Actions.Diff)
        ))

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

    // ── Popup menu ────────────────────────────────────────────────────

    private fun setupPopupMenu() {
        val group = DefaultActionGroup().apply {
            add(object : AnAction("Download", "Download this Flutter version", AllIcons.Actions.Download) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedVersion()?.let { downloadVersion(it.entry.version) }
                }
                override fun update(e: AnActionEvent) {
                    val v = selectedVersion()
                    e.presentation.isEnabledAndVisible = v != null && !v.entry.installed
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            add(object : AnAction("Set as Code Push Version", "Pin this Flutter version to the project", AllIcons.Actions.SetDefault) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedVersion()?.let { pinVersionToProject(it.entry.version) }
                }
                override fun update(e: AnActionEvent) {
                    val v = selectedVersion()
                    e.presentation.isEnabledAndVisible = v != null && v.entry.installed && !v.isSelected
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
            addSeparator()
            add(object : AnAction("Copy Patch ID", "Copy this patch's ID to the clipboard", AllIcons.Actions.Copy) {
                override fun actionPerformed(e: AnActionEvent) {
                    selectedPatch()?.id?.let { copyToClipboard(it, "Copied patch ID") }
                }
                override fun update(e: AnActionEvent) {
                    e.presentation.isEnabledAndVisible = selectedPatch()?.id != null
                }
                override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.EDT
            })
        }

        tree.addMouseListener(object : MouseAdapter() {
            override fun mousePressed(e: MouseEvent) = maybeHandle(e)
            override fun mouseReleased(e: MouseEvent) = maybeHandle(e)
            override fun mouseClicked(e: MouseEvent) {
                if (e.button == MouseEvent.BUTTON1 && e.clickCount == 1) {
                    val path = tree.getPathForLocation(e.x, e.y) ?: return
                    val node = path.lastPathComponent as? DefaultMutableTreeNode ?: return
                    if (node.userObject === InitAppLink) {
                        codePushInit()
                    }
                }
            }
            private fun maybeHandle(e: MouseEvent) {
                if (e.isPopupTrigger) {
                    val path = tree.getPathForLocation(e.x, e.y) ?: return
                    tree.selectionPath = path
                    val popupMenu = ActionManager.getInstance()
                        .createActionPopupMenu(Constants.POPUP_CODE_PUSH_TREE, group)
                    popupMenu.component.show(tree, e.x, e.y)
                }
            }
        })
    }

    private fun selectedVersion(): VersionRow? {
        val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return null
        return node.userObject as? VersionRow
    }

    private fun selectedPatch(): CodePushPatch? {
        val node = tree.lastSelectedPathComponent as? DefaultMutableTreeNode ?: return null
        return (node.userObject as? PatchRow)?.patch
    }

    // ── Version actions ───────────────────────────────────────────────

    private fun downloadVersion(version: String) {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Installing Flutter SDK $version...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = SdkBackendProvider.get().installSdk(version, indicator)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            notify("Installed Flutter $version", NotificationType.INFORMATION)
                            refresh()
                        } else {
                            notify("Failed to install Flutter $version", NotificationType.ERROR)
                        }
                    }
                }
            }
        )
    }

    private fun pinVersionToProject(version: String) {
        val projectPath = project.basePath ?: return
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Setting code push version to $version...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = SdkBackendProvider.get().pinToProject(version, projectPath)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            SdkPathUpdater.updateFlutterSdkPath(project, version)
                            notify("Code push will use Flutter $version", NotificationType.INFORMATION)
                            refresh()
                        } else {
                            notify("Failed to pin Flutter $version", NotificationType.ERROR)
                        }
                    }
                }
            }
        )
    }

    // ── Login / Init / Release / Patch ────────────────────────────────

    private fun codePushLogin() {
        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath codepush login"
        openTerminalWithCommand(command)

        // Terminal APIs don't expose a clean completion callback, so poll the
        // account state and refresh once the login flips logged_in → true.
        val start = System.currentTimeMillis()
        val timeoutMs = 5 * 60 * 1000L
        val runnable = object : Runnable {
            override fun run() {
                if (System.currentTimeMillis() - start > timeoutMs) return
                val acct = try {
                    FlutterCompileCli.codePushAccount()
                } catch (_: Exception) {
                    CodePushAccount()
                }
                if (acct.logged_in) {
                    ApplicationManager.getApplication().invokeLater { refresh() }
                    return
                }
                loginPollExecutor.schedule(this, 2, TimeUnit.SECONDS)
            }
        }
        loginPollExecutor.schedule(runnable, 2, TimeUnit.SECONDS)
    }

    private fun codePushInit() {
        val cliPath = FlutterCompileCli.resolvedCliPath()
        openTerminalWithCommand("$cliPath codepush init")
    }

    private fun codePushRelease() {
        val platforms = arrayOf("apk", "ios", "linux", "macos", "windows")
        val platform = com.intellij.openapi.ui.Messages.showEditableChooseDialog(
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
        val rollout = com.intellij.openapi.ui.Messages.showInputDialog(
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
            notify("Could not open terminal. Run manually: $command", NotificationType.ERROR)
        }
    }

    private fun copyToClipboard(text: String, notifyTitle: String) {
        CopyPasteManager.getInstance().setContents(StringSelection(text))
        notify("$notifyTitle: $text", NotificationType.INFORMATION)
    }

    private fun notify(message: String, type: NotificationType) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup(Constants.NOTIFICATION_GROUP)
            .createNotification(message, type)
            .notify(project)
    }

    // ── Data rows ─────────────────────────────────────────────────────

    /** Data wrapper for info rows in the tree. */
    data class InfoRow(val label: String, val value: String, val icon: Icon)

    /** Data wrapper for release rows in the tree. */
    data class ReleaseRow(val release: CodePushRelease)

    /** Data wrapper for patch rows in the tree. */
    data class PatchRow(val patch: CodePushPatch)

    /** Data wrapper for a supported Flutter version row. */
    data class VersionRow(val entry: CodePushVersionEntry, val isSelected: Boolean)

    /** Marker sentinel for the "Init App" clickable link row. */
    object InitAppLink

    // ── Cell renderer ─────────────────────────────────────────────────

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
                    icon = if (patch.is_active) AllIcons.RunConfigurations.TestPassed else AllIcons.RunConfigurations.TestFailed
                    append("Patch #${patch.number}", SimpleTextAttributes.REGULAR_ATTRIBUTES)
                    val status = if (patch.is_active) "active" else "inactive"
                    append("  ${patch.rollout_percentage}% rollout, $status", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    patch.created_at?.let {
                        append("  \u2022 $it", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    }
                }
                is VersionRow -> {
                    val entry = obj.entry
                    icon = when {
                        obj.isSelected -> AllIcons.Actions.Checked
                        entry.installed -> AllIcons.General.InspectionsOK
                        else -> AllIcons.General.Information
                    }
                    append("v${entry.version}", SimpleTextAttributes.REGULAR_BOLD_ATTRIBUTES)
                    val suffix = when {
                        obj.isSelected -> "selected"
                        entry.installed -> "installed"
                        else -> "not installed"
                    }
                    append("  $suffix", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    entry.platforms?.takeIf { it.isNotEmpty() }?.let {
                        append("  [${it.joinToString(", ")}]", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    }
                    entry.build_revision?.let {
                        append("  \u2022 $it", SimpleTextAttributes.GRAYED_ATTRIBUTES)
                    }
                }
                InitAppLink -> {
                    icon = AllIcons.General.Add
                    append("Init App", SimpleTextAttributes.LINK_ATTRIBUTES)
                }
            }
        }
    }
}
