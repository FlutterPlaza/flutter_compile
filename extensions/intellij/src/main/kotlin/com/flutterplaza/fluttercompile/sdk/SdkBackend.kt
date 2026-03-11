package com.flutterplaza.fluttercompile.sdk

import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.intellij.openapi.progress.ProgressIndicator

/** Backend interface that all SDK managers must implement. */
interface SdkBackend {
    fun listSdks(projectPath: String? = null): List<SdkEntry>
    fun getGlobalSdkVersion(): String?
    fun setGlobalSdk(version: String): Boolean
    fun installSdk(version: String, indicator: ProgressIndicator? = null): Boolean
    fun removeSdk(version: String): Boolean
    fun pinToProject(version: String, projectPath: String): Boolean
    fun unpinFromProject(projectPath: String): Boolean
    fun getSdkPath(version: String): String?
    fun isSdkInstalled(version: String): Boolean
}
