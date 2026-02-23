package com.flutterplaza.fluttercompile.settings

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.flutterplaza.fluttercompile.toolwindow.FlutterCompileToolWindowFactory
import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.project.ProjectManager
import com.intellij.openapi.ui.DialogPanel
import com.intellij.ui.dsl.builder.bindItem
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel
import com.intellij.ui.dsl.builder.toNullableProperty

class FlutterCompileConfigurable : BoundConfigurable(Constants.PLUGIN_NAME) {
    private val settings = FlutterCompileSettings.getInstance()

    override fun createPanel(): DialogPanel = panel {
        row(Constants.LABEL_SDK_MANAGER) {
            comboBox(listOf(Constants.MODE_NATIVE, Constants.MODE_FVM))
                .bindItem(settings::sdkManager.toNullableProperty())
                .comment(Constants.COMMENT_SDK_MANAGER)
        }
        row(Constants.LABEL_CLI_PATH) {
            textField()
                .bindText(settings::cliPath)
                .comment(Constants.COMMENT_CLI_PATH)
        }
    }

    override fun apply() {
        super.apply()
        SdkBackendProvider.reload()
        // Refresh any open tool window panels so they pick up the new backend
        for (project in ProjectManager.getInstance().openProjects) {
            FlutterCompileToolWindowFactory.getPanel(project)?.let { panel ->
                panel.syncMode()
                panel.refreshAll()
            }
        }
    }
}
