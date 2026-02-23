package com.flutterplaza.fluttercompile.terminal

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.sdk.SdkBackendProvider
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import org.jetbrains.plugins.terminal.LocalTerminalCustomizer
import java.io.File

/**
 * Injects the resolved Flutter SDK into the terminal environment.
 *
 * Resolution order: project `.flutter-version` → global default.
 * This ensures that `flutter` and `dart` in any IDE terminal point
 * to the SDK managed by flutter_compile, matching the behaviour of
 * the Dart analysis server and code completion.
 */
class SdkTerminalCustomizer : LocalTerminalCustomizer() {

    companion object {
        private val LOG = Logger.getInstance(SdkTerminalCustomizer::class.java)
    }

    override fun customizeCommandAndEnvironment(
        project: Project,
        workingDirectory: String?,
        command: Array<out String>,
        envs: MutableMap<String, String>
    ): Array<out String> {
        try {
            val backend = SdkBackendProvider.get()

            // Resolve: project .flutter-version first, then global
            var sdkVersion: String? = null

            val projectPath = project.basePath
            if (projectPath != null) {
                val fvFile = File(projectPath, Constants.FLUTTER_VERSION_FILE)
                if (fvFile.exists()) {
                    val content = fvFile.readText().trim()
                    if (content.isNotEmpty()) {
                        sdkVersion = content
                    }
                }
            }

            if (sdkVersion == null) {
                sdkVersion = backend.getGlobalSdkVersion()
            }

            if (sdkVersion == null) {
                return command
            }

            val sdkPath = backend.getSdkPath(sdkVersion) ?: return command

            val flutterBin = File(sdkPath, "bin").absolutePath
            val dartBin = File(sdkPath, "bin${File.separator}cache${File.separator}dart-sdk${File.separator}bin").absolutePath
            val pubCache = File(sdkPath, ".pub-cache").absolutePath

            val sep = File.pathSeparator
            val currentPath = envs["PATH"] ?: ""
            envs["PATH"] = "$flutterBin$sep$dartBin$sep$currentPath"
            envs[Constants.ENV_PUB_CACHE] = pubCache
            envs[Constants.ENV_FLUTTER_COMPILE_SDK] = sdkPath

            LOG.info("Terminal SDK: $sdkVersion ($sdkPath)")
        } catch (e: Exception) {
            LOG.warn("Failed to configure terminal SDK environment", e)
        }

        return command
    }
}
