package com.flutterplaza.fluttercompile.startup

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.flutterplaza.fluttercompile.settings.FlutterCompileSettings
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.ide.BrowserUtil
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity

/**
 * Checks availability of the required tools when a project opens.
 *
 * - Native mode: checks that `git` is available (SDK ops need it).
 * - FVM mode: checks that `fvm` is available.
 * - Also shows a soft info notification if the CLI is missing (needed for doctor/engine).
 */
class CliAvailabilityChecker : ProjectActivity {

    override suspend fun execute(project: Project) {
        val mode = FlutterCompileSettings.getInstance().sdkManager

        if (mode == Constants.MODE_FVM) {
            if (!isCommandAvailable(Constants.CMD_FVM)) {
                NotificationGroupManager.getInstance()
                    .getNotificationGroup(Constants.NOTIFICATION_GROUP)
                    .createNotification(
                        Constants.NOTIFY_FVM_NOT_FOUND,
                        Constants.MSG_FVM_NOT_FOUND,
                        NotificationType.WARNING,
                    )
                    .addAction(object : AnAction(Constants.ACTION_INSTALL_FVM) {
                        override fun actionPerformed(e: AnActionEvent) {
                            BrowserUtil.browse(Constants.URL_FVM_INSTALL)
                        }
                    })
                    .notify(project)
            }
        } else {
            if (!isCommandAvailable(Constants.CMD_GIT)) {
                NotificationGroupManager.getInstance()
                    .getNotificationGroup(Constants.NOTIFICATION_GROUP)
                    .createNotification(
                        Constants.NOTIFY_GIT_NOT_FOUND,
                        Constants.MSG_GIT_NOT_FOUND,
                        NotificationType.WARNING,
                    )
                    .notify(project)
            }
        }

        // Soft info about CLI availability (for doctor/engine features)
        if (!FlutterCompileCli.isCliAvailable()) {
            NotificationGroupManager.getInstance()
                .getNotificationGroup(Constants.NOTIFICATION_GROUP)
                .createNotification(
                    Constants.NOTIFY_CLI_NOT_FOUND,
                    Constants.MSG_CLI_NOT_FOUND,
                    NotificationType.INFORMATION,
                )
                .addAction(object : AnAction(Constants.ACTION_INSTALL_INSTRUCTIONS) {
                    override fun actionPerformed(e: AnActionEvent) {
                        BrowserUtil.browse(Constants.URL_PUB_PACKAGE)
                    }
                })
                .notify(project)
        }
    }

    private fun isCommandAvailable(command: String): Boolean {
        return try {
            val lookup = if (System.getProperty(Constants.SYS_OS_NAME).lowercase().contains(Constants.OS_WINDOWS_MARKER)) Constants.CMD_WHERE else Constants.CMD_WHICH
            val cmd = GeneralCommandLine(lookup, command)
                .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
            val handler = CapturingProcessHandler(cmd)
            val result = handler.runProcess(10_000)
            result.exitCode == 0
        } catch (_: Exception) {
            false
        }
    }
}
