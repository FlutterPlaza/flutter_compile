package com.flutterplaza.fluttercompile.startup

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.ide.BrowserUtil
import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.project.Project
import com.intellij.openapi.startup.ProjectActivity

/**
 * Checks if the `flutter_compile` CLI is available when a project opens.
 * Shows a notification balloon with an install link if not found.
 */
class CliAvailabilityChecker : ProjectActivity {

    override suspend fun execute(project: Project) {
        if (!FlutterCompileCli.isCliAvailable()) {
            NotificationGroupManager.getInstance()
                .getNotificationGroup("Flutter Compile")
                .createNotification(
                    "flutter_compile CLI not found",
                    "The flutter_compile CLI is not installed or not on PATH. " +
                        "Install it to manage Flutter SDKs.",
                    NotificationType.WARNING,
                )
                .addAction(object : AnAction("Install Instructions") {
                    override fun actionPerformed(e: AnActionEvent) {
                        BrowserUtil.browse("https://pub.dev/packages/flutter_compile")
                    }
                })
                .notify(project)
        }
    }
}
