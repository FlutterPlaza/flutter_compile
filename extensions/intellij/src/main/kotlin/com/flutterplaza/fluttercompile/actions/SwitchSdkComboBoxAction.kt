package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.flutterplaza.fluttercompile.settings.SdkPathUpdater
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.DefaultActionGroup
import com.intellij.openapi.actionSystem.ex.ComboBoxAction
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import javax.swing.JComponent
import com.intellij.openapi.actionSystem.DataContext

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
        // Refresh SDK list in background
        sdks = FlutterCompileCli.listSdks()
        currentVersion = FlutterCompileCli.getGlobalSdkVersion()

        e.presentation.isEnabled = true
        e.presentation.text = currentVersion?.let { "Flutter SDK: $it" } ?: "Flutter SDK: (none)"
    }

    @Deprecated("Use createPopupActionGroup(JComponent, DataContext) when available")
    override fun createPopupActionGroup(button: JComponent): DefaultActionGroup {
        val group = DefaultActionGroup()
        for (sdk in sdks) {
            group.add(SdkSelectionAction(sdk))
        }
        return group
    }

    /** Action for a single SDK entry in the dropdown. */
    private inner class SdkSelectionAction(
        private val sdk: SdkEntry,
    ) : com.intellij.openapi.actionSystem.AnAction(sdk.displayLabel()) {

        override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

        override fun actionPerformed(e: AnActionEvent) {
            val project = e.project ?: return
            ProgressManager.getInstance().run(
                object : Task.Backgroundable(project, "Switching to Flutter SDK ${sdk.version}...") {
                    override fun run(indicator: ProgressIndicator) {
                        val success = FlutterCompileCli.setGlobalSdk(sdk.version)
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
