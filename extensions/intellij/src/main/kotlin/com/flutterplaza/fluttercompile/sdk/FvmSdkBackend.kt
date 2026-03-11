package com.flutterplaza.fluttercompile.sdk

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.reflect.TypeToken
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.progress.ProgressIndicator

/** FVM SDK backend that delegates to the `fvm` CLI. */
class FvmSdkBackend : SdkBackend {

    companion object {
        private val LOG = Logger.getInstance(FvmSdkBackend::class.java)
        private val gson = Gson()
    }

    private fun runFvm(vararg args: String): String? {
        return try {
            val cmd = GeneralCommandLine(Constants.CMD_FVM, *args)
                .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
            val handler = CapturingProcessHandler(cmd)
            val result = handler.runProcess(120_000)
            if (result.exitCode == 0) result.stdout.trim() else null
        } catch (e: Exception) {
            LOG.warn("fvm ${args.joinToString(" ")} failed", e)
            null
        }
    }

    override fun listSdks(projectPath: String?): List<SdkEntry> {
        val raw = runFvm("api", "list") ?: return emptyList()
        return try {
            val json = gson.fromJson(raw, JsonObject::class.java)
            val versions = json.getAsJsonArray("versions") ?: return emptyList()

            // Get context for global/project markers
            var globalVersion: String? = null
            var projectVersion: String? = null
            try {
                val ctxRaw = runFvm("api", "context")
                if (ctxRaw != null) {
                    val ctx = gson.fromJson(ctxRaw, JsonObject::class.java)
                    globalVersion = ctx.getAsJsonObject("global")
                        ?.get("version")?.asString
                    val proj = ctx.getAsJsonObject("project")
                    projectVersion = proj?.get("pinnedVersion")?.asString
                        ?: proj?.get("version")?.asString
                }
            } catch (_: Exception) {
                // context may fail if no project
            }

            versions.map { elem ->
                val obj = elem.asJsonObject
                val name = obj.get("name").asString
                SdkEntry(
                    version = name,
                    path = obj.get("directory")?.asString ?: "",
                    global = name == globalVersion,
                    project = name == projectVersion,
                    contributor = false,
                )
            }
        } catch (e: Exception) {
            LOG.warn("Failed to parse fvm api list output", e)
            emptyList()
        }
    }

    override fun getGlobalSdkVersion(): String? {
        val raw = runFvm("api", "context") ?: return null
        return try {
            val ctx = gson.fromJson(raw, JsonObject::class.java)
            ctx.getAsJsonObject("global")?.get("version")?.asString
        } catch (e: Exception) {
            LOG.warn("Failed to parse fvm api context output", e)
            null
        }
    }

    override fun setGlobalSdk(version: String): Boolean {
        return runFvm("global", version) != null
    }

    override fun installSdk(version: String, indicator: ProgressIndicator?): Boolean {
        indicator?.text = "Installing Flutter SDK '$version' via FVM..."
        return runFvm("install", version) != null
    }

    override fun removeSdk(version: String): Boolean {
        return runFvm("remove", version) != null
    }

    override fun pinToProject(version: String, projectPath: String): Boolean {
        return runFvm("use", version, "--project", projectPath) != null
    }

    override fun unpinFromProject(projectPath: String): Boolean {
        val fvmRc = java.io.File(projectPath, Constants.FVM_RC_FILE)
        if (!fvmRc.exists()) return true // already unpinned
        return try {
            fvmRc.delete()
        } catch (e: Exception) {
            LOG.warn("Failed to unpin SDK from project", e)
            false
        }
    }

    override fun getSdkPath(version: String): String? {
        val raw = runFvm("api", "list") ?: return null
        return try {
            val json = gson.fromJson(raw, JsonObject::class.java)
            val versions = json.getAsJsonArray("versions") ?: return null
            versions.firstOrNull { it.asJsonObject.get("name").asString == version }
                ?.asJsonObject?.get("directory")?.asString
        } catch (e: Exception) {
            LOG.warn("Failed to resolve FVM SDK path for '$version'", e)
            null
        }
    }

    override fun isSdkInstalled(version: String): Boolean {
        val raw = runFvm("api", "list") ?: return false
        return try {
            val json = gson.fromJson(raw, JsonObject::class.java)
            val versions = json.getAsJsonArray("versions") ?: return false
            versions.any { it.asJsonObject.get("name").asString == version }
        } catch (_: Exception) {
            false
        }
    }
}
