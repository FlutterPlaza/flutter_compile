package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages
import org.jetbrains.plugins.terminal.TerminalToolWindowManager

class CodePushLoginAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val apiKey = Messages.showInputDialog(
            project,
            "Enter your Code Push API key:",
            "Code Push Login",
            null,
        ) ?: return

        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath codepush login --api-key $apiKey"
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_CODE_PUSH)
            widget.executeCommand(command)
        } catch (ex: Exception) {
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
}

class CodePushReleaseAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
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
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_CODE_PUSH)
            widget.executeCommand(command)
        } catch (ex: Exception) {
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
}

class CodePushPatchAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
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
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_CODE_PUSH)
            widget.executeCommand(command)
        } catch (ex: Exception) {
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
}

class CodePushRollbackAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val patchId = Messages.showInputDialog(
            project,
            "Enter Patch ID to rollback:",
            "Code Push Rollback",
            null,
        ) ?: return

        val cliPath = FlutterCompileCli.resolvedCliPath()
        val command = "$cliPath codepush rollback --patch-id $patchId"
        try {
            @Suppress("DEPRECATION")
            val widget = TerminalToolWindowManager.getInstance(project)
                .createLocalShellWidget(project.basePath, Constants.TERMINAL_CODE_PUSH)
            widget.executeCommand(command)
        } catch (ex: Exception) {
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
}
