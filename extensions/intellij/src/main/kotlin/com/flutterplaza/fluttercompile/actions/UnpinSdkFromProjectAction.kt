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
import java.io.File

/** Removes the Flutter SDK pin from the current project. */
class UnpinSdkFromProjectAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val projectPath = project.basePath ?: return
        val backend = SdkBackendProvider.get()

        val fvFile = File(projectPath, Constants.FLUTTER_VERSION_FILE)
        val fvmRc = File(projectPath, Constants.FVM_RC_FILE)
        if (!fvFile.exists() && !fvmRc.exists()) {
            Messages.showInfoMessage(project, Constants.MSG_NO_SDK_PINNED, Constants.PLUGIN_NAME)
            return
        }

        val choice = Messages.showOkCancelDialog(
            project,
            Constants.MSG_CONFIRM_UNPIN,
            Constants.DIALOG_UNPIN_SDK,
            Messages.getOkButton(),
            Messages.getCancelButton(),
            Messages.getQuestionIcon(),
        )
        if (choice != Messages.OK) return

        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Unpinning Flutter SDK from project...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = backend.unpinFromProject(projectPath)
                    if (success) {
                        ApplicationManager.getApplication().invokeLater {
                            val globalVersion = backend.getGlobalSdkVersion()
                            if (globalVersion != null) {
                                SdkPathUpdater.updateFlutterSdkPath(project, globalVersion)
                            }
                            FlutterCompileToolWindowFactory.getPanel(project)?.refreshAll()
                        }
                    }
                }
            }
        )
    }
}
