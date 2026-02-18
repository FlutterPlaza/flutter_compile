package com.flutterplaza.fluttercompile.settings

import com.flutterplaza.fluttercompile.cli.FlutterCompileCli
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.projectRoots.ProjectJdkTable
import com.intellij.openapi.roots.ProjectRootManager
import io.flutter.sdk.FlutterSdk
import io.flutter.sdk.FlutterSdkUtil

/**
 * Updates the Flutter SDK path in IntelliJ / Android Studio project settings
 * when the user switches SDK versions.
 */
object SdkPathUpdater {
    private val LOG = Logger.getInstance(SdkPathUpdater::class.java)

    /**
     * Update the project's Flutter SDK path to point to [version]'s install directory.
     *
     * This uses the Flutter IntelliJ plugin's API to locate and update the SDK reference.
     * Must be called on the EDT (Event Dispatch Thread).
     */
    fun updateFlutterSdkPath(project: Project, version: String) {
        val sdkPath = FlutterCompileCli.getSdkPath(version)
        if (sdkPath == null) {
            LOG.warn("Could not resolve SDK path for version $version")
            return
        }

        try {
            FlutterSdkUtil.updateKnownSdkPaths(sdkPath)
            LOG.info("Updated Flutter SDK path to $sdkPath for version $version")
        } catch (e: Exception) {
            LOG.warn("Failed to update Flutter SDK path", e)
        }
    }
}
