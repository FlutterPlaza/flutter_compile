package com.flutterplaza.fluttercompile.actions

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.ui.Messages
import com.intellij.ide.actions.RevealFileAction
import java.io.File

/** Opens an SDK's install directory in the system file manager. */
class OpenSdkFolderAction : AnAction() {

    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val sdks = FlutterCompileCli.listSdks()
        if (sdks.isEmpty()) {
            Messages.showInfoMessage(project, "No SDKs installed.", "Flutter Compile")
            return
        }

        val versions = sdks.map { it.displayLabel() }.toTypedArray()
        val choice = Messages.showChooseDialog(
            project,
            "Select SDK folder to open:",
            "Open SDK Folder",
            null,
            versions,
            versions.first(),
        )
        if (choice < 0) return

        val selected = sdks[choice]
        val file = File(selected.path)
        if (file.exists()) {
            RevealFileAction.openDirectory(file)
        } else {
            Messages.showErrorDialog(project, "SDK folder not found: ${selected.path}", "Flutter Compile")
        }
    }
}
