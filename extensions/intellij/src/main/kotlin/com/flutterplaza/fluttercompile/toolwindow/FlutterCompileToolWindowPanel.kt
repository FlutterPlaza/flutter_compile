package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.flutterplaza.fluttercompile.settings.SdkPathUpdater
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.project.Project
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTabbedPane
import java.awt.BorderLayout
import javax.swing.*

class FlutterCompileToolWindowPanel(private val project: Project) {
    val component: JComponent

    private val sdkListModel = DefaultListModel<SdkEntry>()
    private val sdkList = JList(sdkListModel)
    private val doctorTextArea = JTextArea().apply {
        isEditable = false
        font = java.awt.Font("Monospaced", java.awt.Font.PLAIN, 12)
    }

    init {
        val tabbedPane = JBTabbedPane()

        // --- SDKs tab ---
        val sdkPanel = JPanel(BorderLayout())
        sdkList.cellRenderer = SdkListCellRenderer()
        sdkList.selectionMode = ListSelectionModel.SINGLE_SELECTION
        sdkPanel.add(JBScrollPane(sdkList), BorderLayout.CENTER)

        val sdkButtonPanel = JPanel()
        val switchButton = JButton("Switch to Selected").apply {
            addActionListener { switchToSelected() }
        }
        val refreshButton = JButton("Refresh").apply {
            addActionListener { refresh() }
        }
        sdkButtonPanel.add(switchButton)
        sdkButtonPanel.add(refreshButton)
        sdkPanel.add(sdkButtonPanel, BorderLayout.SOUTH)

        tabbedPane.addTab("SDKs", sdkPanel)

        // --- Doctor tab ---
        val doctorPanel = JPanel(BorderLayout())
        doctorPanel.add(JBScrollPane(doctorTextArea), BorderLayout.CENTER)
        val doctorRefreshButton = JButton("Run Doctor").apply {
            addActionListener { runDoctor() }
        }
        val doctorButtonPanel = JPanel()
        doctorButtonPanel.add(doctorRefreshButton)
        doctorPanel.add(doctorButtonPanel, BorderLayout.SOUTH)

        tabbedPane.addTab("Doctor", doctorPanel)

        component = tabbedPane

        // Initial load
        refresh()
    }

    private fun refresh() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Loading SDKs...") {
                override fun run(indicator: ProgressIndicator) {
                    val sdks = FlutterCompileCli.listSdks()
                    ApplicationManager.getApplication().invokeLater {
                        sdkListModel.clear()
                        sdks.forEach { sdkListModel.addElement(it) }
                    }
                }
            }
        )
    }

    private fun switchToSelected() {
        val selected = sdkList.selectedValue ?: return
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Switching to ${selected.version}...") {
                override fun run(indicator: ProgressIndicator) {
                    val success = FlutterCompileCli.setGlobalSdk(selected.version)
                    if (success) {
                        ApplicationManager.getApplication().invokeLater {
                            SdkPathUpdater.updateFlutterSdkPath(project, selected.version)
                            refresh()
                        }
                    }
                }
            }
        )
    }

    private fun runDoctor() {
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Running doctor...") {
                override fun run(indicator: ProgressIndicator) {
                    val output = FlutterCompileCli.runDoctor()
                    ApplicationManager.getApplication().invokeLater {
                        doctorTextArea.text = output
                        doctorTextArea.caretPosition = 0
                    }
                }
            }
        )
    }

    /** Custom cell renderer for SDK list entries. */
    private class SdkListCellRenderer : DefaultListCellRenderer() {
        override fun getListCellRendererComponent(
            list: JList<*>,
            value: Any?,
            index: Int,
            isSelected: Boolean,
            cellHasFocus: Boolean,
        ): java.awt.Component {
            val component = super.getListCellRendererComponent(list, value, index, isSelected, cellHasFocus)
            if (value is SdkEntry) {
                text = "<html><b>${value.version}</b> &nbsp; <font color='gray'>${value.path}</font>" +
                    if (value.global || value.project) {
                        val markers = mutableListOf<String>()
                        if (value.global) markers.add("global")
                        if (value.project) markers.add("project")
                        " &nbsp; <font color='#4CAF50'>(${markers.joinToString(", ")})</font>"
                    } else {
                        ""
                    } + "</html>"
            }
            return component
        }
    }
}
