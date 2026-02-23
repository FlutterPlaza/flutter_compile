package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.flutterplaza.fluttercompile.settings.SdkPathUpdater
import com.flutterplaza.fluttercompile.toolwindow.FlutterCompileToolWindowFactory
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.ui.Messages

/** Pins an SDK to the current project via the active backend. */
class PinSdkToProjectAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val projectPath = project.basePath ?: return
        val backend = SdkBackendProvider.get()
        val sdks = backend.listSdks(projectPath)
        if (sdks.isEmpty()) {
            Messages.showInfoMessage(project, Constants.MSG_NO_SDKS_INSTALLED, Constants.PLUGIN_NAME)
            return
        }

        val versions = sdks.map { it.displayLabel() }.toTypedArray()
        val choice = Messages.showChooseDialog(
            project,
            Constants.MSG_SELECT_SDK_PIN,
            Constants.DIALOG_PIN_SDK,
            null,
            versions,
            versions.first(),
        )
        if (choice < 0) return

        val selected = sdks[choice]
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Pinning ${selected.version} to project...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = backend.pinToProject(selected.version, projectPath)
                    if (success) {
                        ApplicationManager.getApplication().invokeLater {
                            SdkPathUpdater.updateFlutterSdkPath(project, selected.version)
                            FlutterCompileToolWindowFactory.getPanel(project)?.refreshAll()
                        }
                    }
                }
            }
        )
    }
}
