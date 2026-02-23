package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.ui.Messages

/** Prompts for a version string and installs the SDK via the active backend. */
class InstallSdkAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val version = Messages.showInputDialog(
            project,
            Constants.MSG_ENTER_SDK_VERSION,
            Constants.DIALOG_INSTALL_SDK,
            null,
        )
        if (version.isNullOrBlank()) return

        val trimmed = version.trim()
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Installing Flutter SDK $trimmed...") {
                override fun run(indicator: ProgressIndicator) {
                    val result = SdkBackendProvider.get().installSdk(trimmed, indicator)
                    ApplicationManager.getApplication().invokeLater {
                        if (result) {
                            Messages.showInfoMessage(project, "Flutter SDK $trimmed installed.", Constants.PLUGIN_NAME)
                        } else {
                            Messages.showErrorDialog(project, "Failed to install Flutter SDK $trimmed.", Constants.PLUGIN_NAME)
                        }
                    }
                }
            }
        )
    }
}
