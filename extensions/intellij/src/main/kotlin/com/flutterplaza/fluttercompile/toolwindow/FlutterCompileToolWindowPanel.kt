package com.flutterplaza.fluttercompile.toolwindow

import com.intellij.openapi.project.Project
import com.intellij.ui.components.JBTabbedPane
import javax.swing.JComponent

class FlutterCompileToolWindowPanel(private val project: Project) {
    val component: JComponent

    private val sdkTreePanel = SdkTreePanel(project)
    private val doctorTreePanel = DoctorTreePanel(project)
    private val buildsTreePanel = BuildsTreePanel(project)

    init {
        sdkTreePanel.onMutation = { refreshAll() }

        val tabbedPane = JBTabbedPane()
        tabbedPane.addTab("SDKs", sdkTreePanel.component)
        tabbedPane.addTab("Doctor", doctorTreePanel.component)
        tabbedPane.addTab("Engine Builds", buildsTreePanel.component)

        component = tabbedPane

        // Initial load
        refreshAll()
    }

    /** Refresh all three tabs. */
    fun refreshAll() {
        sdkTreePanel.refresh()
        doctorTreePanel.refresh()
        buildsTreePanel.refresh()
    }

    /** Refresh only the SDK tree (e.g. from version file changes). */
    fun refreshSdks() {
        sdkTreePanel.refresh()
    }
}
