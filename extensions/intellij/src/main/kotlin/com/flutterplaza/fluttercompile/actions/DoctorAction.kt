package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.toolwindow.FlutterCompileToolWindowFactory
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.wm.ToolWindowManager

/** Runs `flutter_compile doctor` and displays the output in the Flutter Compile tool window. */
class DoctorAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        ApplicationManager.getApplication().invokeLater {
            val toolWindow = ToolWindowManager.getInstance(project)
                .getToolWindow(Constants.TOOL_WINDOW_ID)
            toolWindow?.activate {
                FlutterCompileToolWindowFactory.getPanel(project)?.refreshAll()
            }
        }
    }
}
