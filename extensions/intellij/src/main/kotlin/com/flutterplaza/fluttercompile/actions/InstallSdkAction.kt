package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.ui.Messages

/** Prompts for a version string and runs `flutter_compile sdk install <version>`. */
class InstallSdkAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val version = Messages.showInputDialog(
            project,
            "Enter Flutter SDK version or channel to install:",
            "Install Flutter SDK",
            null,
        )
        if (version.isNullOrBlank()) return

        val trimmed = version.trim()
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Installing Flutter SDK $trimmed...") {
                override fun run(indicator: ProgressIndicator) {
                    val result = FlutterCompileCli.installSdk(trimmed)
                    ApplicationManager.getApplication().invokeLater {
                        if (result) {
                            Messages.showInfoMessage(project, "Flutter SDK $trimmed installed.", "Flutter Compile")
                        } else {
                            Messages.showErrorDialog(project, "Failed to install Flutter SDK $trimmed.", "Flutter Compile")
                        }
                    }
                }
            }
        )
    }
}
