package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.flutterplaza.fluttercompile.settings.FlutterCompileSettings
import com.intellij.openapi.project.Project
import com.intellij.ui.components.JBTabbedPane
import java.awt.BorderLayout
import java.awt.FlowLayout
import javax.swing.JComboBox
import javax.swing.JComponent
import javax.swing.JLabel
import javax.swing.JPanel

class FlutterCompileToolWindowPanel(private val project: Project) {
    val component: JComponent

    private val sdkTreePanel = SdkTreePanel(project)
    private val doctorTreePanel = DoctorTreePanel(project)
    private val buildsTreePanel = BuildsTreePanel(project)
    private val codePushTreePanel = CodePushTreePanel(project)

    private val modeCombo = JComboBox(arrayOf(Constants.MODE_NATIVE, Constants.MODE_FVM))

    init {
        sdkTreePanel.onMutation = { refreshAll() }

        // Mode toggle bar
        val settings = FlutterCompileSettings.getInstance()
        modeCombo.selectedItem = settings.sdkManager
        modeCombo.addActionListener {
            val selected = modeCombo.selectedItem as? String ?: return@addActionListener
            if (selected != settings.sdkManager) {
                settings.sdkManager = selected
                SdkBackendProvider.reload()
                refreshAll()
            }
        }
        val modeBar = JPanel(FlowLayout(FlowLayout.LEFT, 4, 2)).apply {
            add(JLabel(Constants.LABEL_MODE))
            add(modeCombo)
        }

        val tabbedPane = JBTabbedPane()
        tabbedPane.addTab(Constants.TAB_SDKS, sdkTreePanel.component)
        tabbedPane.addTab(Constants.TAB_DOCTOR, doctorTreePanel.component)
        tabbedPane.addTab(Constants.TAB_ENGINE_BUILDS, buildsTreePanel.component)
        tabbedPane.addTab(Constants.CODE_PUSH_TAB_TITLE, codePushTreePanel.component)

        component = JPanel(BorderLayout()).apply {
            add(modeBar, BorderLayout.NORTH)
            add(tabbedPane, BorderLayout.CENTER)
        }

        // Initial load
        refreshAll()
    }

    /** Refresh all tabs. */
    fun refreshAll() {
        sdkTreePanel.refresh()
        doctorTreePanel.refresh()
        buildsTreePanel.refresh()
        codePushTreePanel.refresh()
    }

    /** Refresh only the SDK tree (e.g. from version file changes). */
    fun refreshSdks() {
        sdkTreePanel.refresh()
    }

    /** Sync the mode combo with current settings (e.g. after Settings dialog apply). */
    fun syncMode() {
        val current = FlutterCompileSettings.getInstance().sdkManager
        if (modeCombo.selectedItem != current) {
            modeCombo.selectedItem = current
        }
    }
}
