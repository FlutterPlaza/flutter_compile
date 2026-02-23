package com.flutterplaza.fluttercompile.listeners

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.settings.FlutterCompileSettings
import com.flutterplaza.fluttercompile.toolwindow.FlutterCompileToolWindowFactory
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.newvfs.BulkFileListener
import com.intellij.openapi.vfs.newvfs.events.VFileContentChangeEvent
import com.intellij.openapi.vfs.newvfs.events.VFileCreateEvent
import com.intellij.openapi.vfs.newvfs.events.VFileDeleteEvent
import com.intellij.openapi.vfs.newvfs.events.VFileEvent

/**
 * Watches for `.flutter-version` and `.fvmrc` file changes and triggers SDK tree refresh.
 *
 * Registered as a project-level listener in plugin.xml.
 */
class VersionFileListener(private val project: Project) : BulkFileListener {

    override fun after(events: MutableList<out VFileEvent>) {
        val mode = FlutterCompileSettings.getInstance().sdkManager
        val watchedFiles = if (mode == Constants.MODE_FVM) {
            setOf(Constants.FLUTTER_VERSION_FILE, Constants.FVM_RC_FILE)
        } else {
            setOf(Constants.FLUTTER_VERSION_FILE)
        }

        val hasVersionChange = events.any { event ->
            val name = when (event) {
                is VFileCreateEvent -> event.childName
                is VFileDeleteEvent -> event.file.name
                is VFileContentChangeEvent -> event.file.name
                else -> null
            }
            name in watchedFiles
        }

        if (hasVersionChange) {
            FlutterCompileToolWindowFactory.getPanel(project)?.refreshSdks()
        }
    }
}
