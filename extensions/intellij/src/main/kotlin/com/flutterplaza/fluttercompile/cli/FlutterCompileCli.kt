package com.flutterplaza.fluttercompile.cli

import com.flutterplaza.fluttercompile.settings.FlutterCompileSettings
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.openapi.diagnostic.Logger

/** Wrapper around the `flutter_compile` CLI. */
object FlutterCompileCli {
    private val LOG = Logger.getInstance(FlutterCompileCli::class.java)
    private val gson = Gson()

    private fun cliPath(): String =
        FlutterCompileSettings.getInstance().cliPath.ifBlank { "flutter_compile" }

    /** Execute `flutter_compile` with [args] and return stdout. */
    private fun run(vararg args: String): String? {
        return try {
            val cmd = GeneralCommandLine(cliPath(), *args)
                .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
            val handler = CapturingProcessHandler(cmd)
            val result = handler.runProcess(120_000)
            if (result.exitCode == 0) result.stdout.trim() else null
        } catch (e: Exception) {
            LOG.warn("flutter_compile ${args.joinToString(" ")} failed", e)
            null
        }
    }

    /** Get installed SDKs via `sdk list --json`. */
    fun listSdks(): List<SdkEntry> {
        val raw = run("sdk", "list", "--json") ?: return emptyList()
        return try {
            val type = object : TypeToken<List<SdkEntry>>() {}.type
            gson.fromJson(raw, type)
        } catch (e: Exception) {
            LOG.warn("Failed to parse sdk list JSON", e)
            emptyList()
        }
    }

    /** Get the current global SDK version. */
    fun getGlobalSdkVersion(): String? {
        val raw = run("config", "get", "global_sdk") ?: return null
        // Output: "global_sdk_version:<version>"
        val parts = raw.split(":")
        return if (parts.size == 2 && parts[1].isNotBlank()) parts[1].trim() else null
    }

    /** Set the global default SDK version. */
    fun setGlobalSdk(version: String): Boolean {
        return run("sdk", "global", version) != null
    }

    /** Install an SDK version. Returns true on success. */
    fun installSdk(version: String): Boolean {
        return run("sdk", "install", version) != null
    }

    /** Run doctor and return raw output. */
    fun runDoctor(): String {
        return run("doctor") ?: "Error: failed to run flutter_compile doctor"
    }

    /** Resolve the SDK install path for a given version. */
    fun getSdkPath(version: String): String? {
        val sdks = listSdks()
        return sdks.find { it.version == version }?.path
    }

    /** Run doctor with JSON output and return structured checks. */
    fun runDoctorJson(): List<DoctorCheck> {
        val raw = run("doctor", "--json") ?: return emptyList()
        return try {
            val type = object : TypeToken<List<DoctorCheck>>() {}.type
            gson.fromJson(raw, type)
        } catch (e: Exception) {
            LOG.warn("Failed to parse doctor --json output", e)
            emptyList()
        }
    }

    /** Get engine status via `status --json`. */
    fun getStatus(): EngineStatus {
        val raw = run("status", "--json") ?: return EngineStatus(configured = false)
        return try {
            gson.fromJson(raw, EngineStatus::class.java)
        } catch (e: Exception) {
            LOG.warn("Failed to parse status --json output", e)
            EngineStatus(configured = false)
        }
    }

    /** Remove an installed SDK. Returns true on success. */
    fun removeSdk(version: String): Boolean {
        return run("sdk", "remove", version) != null
    }

    /** Pin SDK to project via `sdk use <version>`. Returns true on success. */
    fun useSdk(version: String): Boolean {
        return run("sdk", "use", version) != null
    }

    /** Check if the CLI is available on PATH. */
    fun isCliAvailable(): Boolean {
        return try {
            val cmd = GeneralCommandLine(cliPath(), "--version")
                .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
            val handler = CapturingProcessHandler(cmd)
            val result = handler.runProcess(10_000)
            result.exitCode == 0
        } catch (_: Exception) {
            false
        }
    }
}
