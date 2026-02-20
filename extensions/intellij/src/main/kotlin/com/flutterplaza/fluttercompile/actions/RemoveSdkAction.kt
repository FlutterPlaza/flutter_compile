package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.flutterplaza.fluttercompile.toolwindow.FlutterCompileToolWindowFactory
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.ui.Messages

/** Prompts the user to select and remove an installed SDK. */
class RemoveSdkAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val sdks = FlutterCompileCli.listSdks().filter { !it.contributor }
        if (sdks.isEmpty()) {
            Messages.showInfoMessage(project, "No removable SDKs installed.", "Flutter Compile")
            return
        }

        val versions = sdks.map { it.displayLabel() }.toTypedArray()
        val choice = Messages.showChooseDialog(
            project,
            "Select SDK to remove:",
            "Remove SDK",
            Messages.getWarningIcon(),
            versions,
            versions.first(),
        )
        if (choice < 0) return

        val selected = sdks[choice]
        val confirm = Messages.showYesNoDialog(
            project,
            "Remove Flutter SDK ${selected.version}?\n\nThis will delete the SDK from disk.",
            "Confirm Remove",
            Messages.getWarningIcon(),
        )
        if (confirm != Messages.YES) return

        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Removing SDK ${selected.version}...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.removeSdk(selected.version)
                    ApplicationManager.getApplication().invokeLater {
                        if (success) {
                            FlutterCompileToolWindowFactory.getPanel(project)?.refreshAll()
                        } else {
                            Messages.showErrorDialog(project, "Failed to remove SDK ${selected.version}.", "Flutter Compile")
                        }
                    }
                }
            }
        )
    }
}
