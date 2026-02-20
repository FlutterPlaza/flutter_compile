package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.toolwindow.FlutterCompileToolWindowFactory
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent

/** Refreshes all panels in the Flutter Compile tool window. */
class RefreshAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        FlutterCompileToolWindowFactory.getPanel(project)?.refreshAll()
    }
}
