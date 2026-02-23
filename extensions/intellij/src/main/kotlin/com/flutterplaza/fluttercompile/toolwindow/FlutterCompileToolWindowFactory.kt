package com.flutterplaza.fluttercompile.toolwindow

import com.flutterplaza.fluttercompile.Constants
import com.intellij.openapi.project.DumbAware
import com.intellij.openapi.project.Project
import com.intellij.openapi.wm.ToolWindow
import com.intellij.openapi.wm.ToolWindowFactory
import com.intellij.ui.content.ContentFactory

class FlutterCompileToolWindowFactory : ToolWindowFactory, DumbAware {

    override fun createToolWindowContent(project: Project, toolWindow: ToolWindow) {
        val panel = FlutterCompileToolWindowPanel(project)
        val content = ContentFactory.getInstance().createContent(panel.component, "", false)
        content.putUserData(PANEL_KEY, panel)
        toolWindow.contentManager.addContent(content)
    }

    companion object {
        val PANEL_KEY = com.intellij.openapi.util.Key.create<FlutterCompileToolWindowPanel>(
            Constants.TOOL_WINDOW_PANEL_KEY_NAME
        )

        /** Retrieve the panel from an open tool window. */
        fun getPanel(project: Project): FlutterCompileToolWindowPanel? {
            val toolWindow = com.intellij.openapi.wm.ToolWindowManager.getInstance(project)
                .getToolWindow(Constants.TOOL_WINDOW_ID) ?: return null
            val content = toolWindow.contentManager.getContent(0) ?: return null
            return content.getUserData(PANEL_KEY)
        }
    }
}
