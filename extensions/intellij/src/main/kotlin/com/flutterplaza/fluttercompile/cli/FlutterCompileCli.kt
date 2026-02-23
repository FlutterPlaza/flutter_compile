package com.flutterplaza.fluttercompile.cli

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.settings.FlutterCompileSettings
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.openapi.diagnostic.Logger
import java.io.File

/** Wrapper around the `flutter_compile` CLI. */
object FlutterCompileCli {
    private val LOG = Logger.getInstance(FlutterCompileCli::class.java)
    private val gson = Gson()

    @Volatile
    private var resolvedPath: String? = null

    /** Return the resolved CLI executable path. */
    fun resolvedCliPath(): String = cliPath()

    private fun cliPath(): String {
        val configured = FlutterCompileSettings.getInstance().cliPath
        if (configured.isNotBlank() && configured != Constants.CLI_DEFAULT_PATH) {
            return configured
        }
        resolvedPath?.let { return it }
        // IntelliJ launched from Dock may not inherit shell PATH.
        // Probe common pub-cache locations where `dart pub global activate` installs binaries.
        val home = System.getProperty(Constants.SYS_USER_HOME)
        val isWin = System.getProperty(Constants.SYS_OS_NAME).lowercase().contains(Constants.OS_WINDOWS_MARKER)
        val bin = if (isWin) Constants.CLI_NAME_WIN else Constants.CLI_NAME
        val candidates = listOfNotNull(
            File(home, "${Constants.PUB_CACHE_BIN_UNIX}/$bin"),
            System.getenv(Constants.ENV_PUB_CACHE)?.let { File(it, "bin/$bin") },
            if (isWin) File(System.getenv(Constants.ENV_LOCAL_APP_DATA) ?: "", "${Constants.PUB_CACHE_BIN_WIN}/$bin") else null,
        )
        for (candidate in candidates) {
            if (candidate.exists() && candidate.canExecute()) {
                resolvedPath = candidate.absolutePath
                LOG.info("Resolved ${Constants.CLI_NAME} CLI at ${candidate.absolutePath}")
                return candidate.absolutePath
            }
        }
        return Constants.CLI_DEFAULT_PATH
    }

    /** Clear the cached resolved path (e.g. after installing the CLI). */
    fun invalidateResolvedPath() {
        resolvedPath = null
    }

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

    /**
     * Extract the first JSON token from CLI output.
     * The CLI may emit log lines (e.g. "MSG : ...", "FINE: ...") on stdout
     * alongside the actual JSON payload. This finds the first line starting
     * with `[` or `{` and returns it.
     */
    private fun extractJson(raw: String): String? {
        return raw.lineSequence().firstOrNull {
            val t = it.trimStart()
            t.startsWith("[") || t.startsWith("{")
        }
    }

    /** Get installed SDKs via `sdk list --json`. */
    fun listSdks(): List<SdkEntry> {
        val raw = run("sdk", "list", "--json") ?: return emptyList()
        val json = extractJson(raw)
        if (json == null) {
            LOG.warn("No JSON found in sdk list output")
            return emptyList()
        }
        return try {
            val type = object : TypeToken<List<SdkEntry>>() {}.type
            gson.fromJson(json, type)
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
        return run("doctor") ?: "Error: failed to run ${Constants.CLI_NAME} doctor"
    }

    /** Resolve the SDK install path for a given version. */
    fun getSdkPath(version: String): String? {
        val sdks = listSdks()
        return sdks.find { it.version == version }?.path
    }

    /** Run doctor with JSON output and return structured checks. */
    fun runDoctorJson(): List<DoctorCheck> {
        val raw = run("doctor", "--json") ?: return emptyList()
        val json = extractJson(raw)
        if (json == null) {
            LOG.warn("No JSON found in doctor --json output")
            return emptyList()
        }
        return try {
            val type = object : TypeToken<List<DoctorCheck>>() {}.type
            gson.fromJson(json, type)
        } catch (e: Exception) {
            LOG.warn("Failed to parse doctor --json output", e)
            emptyList()
        }
    }

    /** Get engine status via `status --json`. */
    fun getStatus(): EngineStatus {
        val raw = run("status", "--json") ?: return EngineStatus(configured = false)
        val json = extractJson(raw)
        if (json == null) {
            LOG.warn("No JSON found in status --json output")
            return EngineStatus(configured = false)
        }
        return try {
            gson.fromJson(json, EngineStatus::class.java)
        } catch (e: Exception) {
            LOG.warn("Failed to parse status --json output", e)
            EngineStatus(configured = false)
        }
    }

    /** Remove an installed SDK. Returns true on success. */
    fun removeSdk(version: String): Boolean {
        return run("sdk", "remove", version) != null
    }

    /** Delete a specific engine build output directory. Returns true on success. */
    fun cleanBuild(buildName: String): Boolean {
        return run("clean", buildName) != null
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

    /**
     * Find the `dart` executable — needed for `dart pub global activate`.
     * Probes PATH, pub-cache, and known Flutter SDK paths from the Flutter plugin.
     */
    fun findDartExecutable(): String? {
        val home = System.getProperty(Constants.SYS_USER_HOME)
        val isWin = System.getProperty(Constants.SYS_OS_NAME).lowercase().contains(Constants.OS_WINDOWS_MARKER)
        val dartBin = if (isWin) Constants.CMD_DART_WIN else Constants.CMD_DART

        // 1. Try `dart` on PATH
        try {
            val lookup = if (isWin) Constants.CMD_WHERE else Constants.CMD_WHICH
            val cmd = GeneralCommandLine(lookup, Constants.CMD_DART)
                .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
            val result = CapturingProcessHandler(cmd).runProcess(5_000)
            if (result.exitCode == 0) {
                val path = result.stdout.trim().lines().first()
                if (path.isNotBlank()) return path
            }
        } catch (_: Exception) { /* fall through */ }

        // 2. Probe known Flutter SDK paths from the Flutter IntelliJ plugin
        try {
            val knownPaths = io.flutter.sdk.FlutterSdkUtil.getKnownFlutterSdkPaths()
            for (sdkPath in knownPaths) {
                val dart = File(sdkPath, "bin/$dartBin")
                if (dart.canExecute()) return dart.absolutePath
            }
        } catch (_: Exception) { /* plugin not available */ }

        // 3. Probe common locations
        val candidates = listOfNotNull(
            File(home, "${Constants.COMPILED_SDK_REL}/bin/$dartBin"),
            File(home, "flutter/bin/$dartBin"),
            if (!isWin) File("/usr/local/bin/dart") else null,
        )
        for (candidate in candidates) {
            if (candidate.canExecute()) return candidate.absolutePath
        }

        return null
    }

    /** Path where depot_tools should be installed. */
    fun depotToolsPath(): String {
        val home = System.getProperty(Constants.SYS_USER_HOME)
        return "$home/${Constants.DEPOT_TOOLS_REL}"
    }

    /** Clone depot_tools to ~/flutter_compile/depot_tools and add to shell PATH. Returns true on success. */
    fun installDepotTools(): Boolean {
        val dest = File(depotToolsPath())
        if (!dest.exists()) {
            dest.parentFile.mkdirs()
            try {
                val cmd = GeneralCommandLine(
                    Constants.CMD_GIT, "clone",
                    Constants.DEPOT_TOOLS_GIT_URL,
                    dest.absolutePath,
                ).withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
                val handler = CapturingProcessHandler(cmd)
                val result = handler.runProcess(300_000)
                if (result.exitCode != 0) return false
            } catch (e: Exception) {
                LOG.warn("Failed to clone depot_tools", e)
                return false
            }
        }

        // Add depot_tools to shell PATH config
        try {
            val home = System.getProperty(Constants.SYS_USER_HOME)
            val shell = System.getenv(Constants.SHELL_ENV_KEY) ?: Constants.DEFAULT_SHELL
            val rcName = if (shell.contains(Constants.SHELL_ZSH)) Constants.SHELL_RC_ZSH else Constants.SHELL_RC_BASH
            val rcFile = File(home, rcName)
            val pathExport = "\n${Constants.DEPOT_TOOLS_PATH_COMMENT_START}\n" +
                    "export PATH=${dest.absolutePath}:\$PATH\n" +
                    "${Constants.DEPOT_TOOLS_PATH_COMMENT_END}\n"
            if (!rcFile.exists()) {
                rcFile.createNewFile()
            }
            val contents = rcFile.readText()
            if (!contents.contains(pathExport.trim())) {
                rcFile.appendText(pathExport)
            }
        } catch (e: Exception) {
            LOG.warn("Failed to add depot_tools to PATH", e)
        }

        return true
    }
}
