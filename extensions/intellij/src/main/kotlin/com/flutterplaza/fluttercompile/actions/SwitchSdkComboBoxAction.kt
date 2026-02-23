package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.flutterplaza.fluttercompile.settings.SdkPathUpdater
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.ex.ComboBoxAction
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.ui.Messages
import javax.swing.JComponent

/**
 * Toolbar combo box that lists installed Flutter SDKs and allows switching.
 * Shows the current global version as the selected item.
 */
class SwitchSdkComboBoxAction : ComboBoxAction() {

    @Volatile
    private var sdks: List<SdkEntry> = emptyList()

    @Volatile
    private var currentVersion: String? = null

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun update(e: AnActionEvent) {
        val backend = SdkBackendProvider.get()
        sdks = backend.listSdks(e.project?.basePath)
        currentVersion = backend.getGlobalSdkVersion()

        e.presentation.isEnabled = true
        e.presentation.text = currentVersion?.let { "Flutter SDK: $it" } ?: "Flutter SDK: (none)"
    }

    @Deprecated("Use createPopupActionGroup(JComponent, DataContext) when available")
    override fun createPopupActionGroup(button: JComponent): DefaultActionGroup {
        val group = DefaultActionGroup()
        for (sdk in sdks) {
            val sdkGroup = DefaultActionGroup(sdk.displayLabel(), true)
            sdkGroup.add(SetGlobalAction(sdk))
            sdkGroup.add(PinToProjectAction(sdk))
            group.add(sdkGroup)
        }
        return group
    }

    /** Sets an SDK as the global default. */
    private inner class SetGlobalAction(
        private val sdk: SdkEntry,
    ) : com.intellij.openapi.actionSystem.AnAction(Constants.ACTION_SET_AS_GLOBAL) {

        override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

        override fun actionPerformed(e: AnActionEvent) {
            val project = e.project ?: return
            ProgressManager.getInstance().run(
                object : Task.Backgroundable(project, "Setting global SDK to ${sdk.version}...") {
                    override fun run(indicator: ProgressIndicator) {
                        val success = SdkBackendProvider.get().setGlobalSdk(sdk.version)
                        if (success) {
                            ApplicationManager.getApplication().invokeLater {
                                SdkPathUpdater.updateFlutterSdkPath(project, sdk.version)
                            }
                        }
                    }
                }
            )
        }
    }

    /** Pins an SDK to the current project. */
    private inner class PinToProjectAction(
        private val sdk: SdkEntry,
    ) : com.intellij.openapi.actionSystem.AnAction(Constants.ACTION_PIN_TO_PROJECT) {

        override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

        override fun actionPerformed(e: AnActionEvent) {
            val project = e.project ?: return
            val projectPath = project.basePath
            if (projectPath == null) {
                Messages.showErrorDialog(project, Constants.MSG_CANNOT_DETERMINE_PATH, Constants.PLUGIN_NAME)
                return
            }
            ProgressManager.getInstance().run(
                object : Task.Backgroundable(project, "Pinning ${sdk.version} to project...") {
                    override fun run(indicator: ProgressIndicator) {
                        val success = SdkBackendProvider.get().pinToProject(sdk.version, projectPath)
                        if (success) {
                            ApplicationManager.getApplication().invokeLater {
                                SdkPathUpdater.updateFlutterSdkPath(project, sdk.version)
                            }
                        }
                    }
                }
            )
        }
    }
}
