package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.progress.ProgressIndicator
import com.intellij.openapi.progress.ProgressManager
import com.intellij.openapi.progress.Task
import com.intellij.openapi.wm.ToolWindowManager

/** Runs `flutter_compile doctor` and displays the output in the Flutter Compile tool window. */
class DoctorAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        ProgressManager.getInstance().run(
            object : Task.Backgroundable(project, "Running flutter_compile doctor...") {
                override fun run(indicator: ProgressIndicator) {
                    val output = FlutterCompileCli.runDoctor()
                    ApplicationManager.getApplication().invokeLater {
                        val toolWindow = ToolWindowManager.getInstance(project)
                            .getToolWindow("Flutter Compile")
                        toolWindow?.activate {
                            // The tool window will refresh its content on activation
                        }
                    }
                }
            }
        )
    }
}
