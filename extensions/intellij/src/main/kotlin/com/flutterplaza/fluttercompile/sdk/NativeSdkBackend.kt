package com.flutterplaza.fluttercompile.sdk

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.cli.SdkEntry
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.execution.process.CapturingProcessHandler
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.progress.ProgressIndicator
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths

/** Native SDK backend that manages Flutter SDKs directly via filesystem + git. */
class NativeSdkBackend : SdkBackend {

    companion object {
        private val LOG = Logger.getInstance(NativeSdkBackend::class.java)

        private fun homeDir(): String = System.getProperty(Constants.SYS_USER_HOME)
        private fun versionsDir(): File = File(homeDir(), Constants.SDK_VERSIONS_REL)
        private fun sdkVersionDir(version: String): File = File(versionsDir(), version)

        /** Resolve the actual SDK directory — compiled SDK lives at ~/flutter_compile/flutter. */
        private fun resolveSdkDir(version: String): File {
            if (version == Constants.COMPILED_VERSION) return File(homeDir(), Constants.COMPILED_SDK_REL)
            return sdkVersionDir(version)
        }

        /** Create or update the `default` symlink to point to [sdkDir]. */
        private fun updateDefaultSdkLink(sdkDir: File) {
            val linkPath = Paths.get(versionsDir().absolutePath, Constants.DEFAULT_SDK_LINK)
            if (Files.exists(linkPath, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
                if (Files.isSymbolicLink(linkPath)) {
                    Files.delete(linkPath)
                } else if (Files.isDirectory(linkPath, java.nio.file.LinkOption.NOFOLLOW_LINKS)) {
                    return // real directory — don't touch
                }
            }
            try { Files.createSymbolicLink(linkPath, sdkDir.toPath()) } catch (e: Exception) {
                LOG.warn("Failed to create default SDK symlink", e)
            }
        }

        /** Remove the `default` symlink if it exists. */
        private fun removeDefaultSdkLink() {
            val linkPath = Paths.get(versionsDir().absolutePath, Constants.DEFAULT_SDK_LINK)
            if (Files.isSymbolicLink(linkPath)) {
                try { Files.delete(linkPath) } catch (e: Exception) {
                    LOG.warn("Failed to remove default SDK symlink", e)
                }
            }
        }
    }

    override fun listSdks(projectPath: String?): List<SdkEntry> {
        val vDir = versionsDir()
        if (!vDir.exists()) return emptyList()

        val entries = vDir.listFiles()
            ?.filter { it.isDirectory && it.name != Constants.DEFAULT_SDK_LINK }
            ?.sortedBy { it.name }
            ?: return emptyList()

        if (entries.isEmpty()) return emptyList()

        val globalVersion = RcConfig.readValue(Constants.GLOBAL_SDK_KEY)?.trim()

        var projectVersion: String? = null
        if (projectPath != null) {
            val fvFile = File(projectPath, Constants.FLUTTER_VERSION_FILE)
            if (fvFile.exists()) {
                projectVersion = fvFile.readText().trim().ifEmpty { null }
            }
        }

        val sdks = entries.map { dir ->
            val trimmedName = dir.name.trim()
            SdkEntry(
                version = trimmedName,
                path = dir.absolutePath,
                global = trimmedName == globalVersion,
                project = trimmedName == projectVersion,
                contributor = false,
            )
        }.toMutableList()

        // Check for contributor (compiled) environment
        val compiledDir = File(homeDir(), Constants.COMPILED_SDK_REL)
        if (compiledDir.exists()) {
            sdks.add(
                SdkEntry(
                    version = Constants.COMPILED_VERSION,
                    path = compiledDir.absolutePath,
                    global = Constants.COMPILED_VERSION == globalVersion,
                    project = Constants.COMPILED_VERSION == projectVersion,
                    contributor = true,
                )
            )
        }

        return sdks
    }

    override fun getGlobalSdkVersion(): String? {
        val value = RcConfig.readValue(Constants.GLOBAL_SDK_KEY)?.trim()
        return if (value.isNullOrEmpty()) null else value
    }

    override fun setGlobalSdk(version: String): Boolean {
        val sdkPath = getSdkPath(version) ?: run {
            LOG.warn("Cannot set global: SDK '$version' is not installed")
            return false
        }
        val sdkDir = File(sdkPath)
        if (!isFlutterSdk(sdkDir)) {
            LOG.warn("Cannot set global: SDK '$version' is not a valid Flutter SDK")
            return false
        }
        RcConfig.writeValue(Constants.GLOBAL_SDK_KEY, version.trim())

        // Update shell config so new terminal sessions use this SDK
        val pubCachePath = File(sdkDir, ".pub-cache").absolutePath
        ShellConfig.updatePath(sdkDir.absolutePath, pubCachePath)

        // Update the `default` symlink
        updateDefaultSdkLink(sdkDir)

        return true
    }

    override fun installSdk(version: String, indicator: ProgressIndicator?): Boolean {
        val target = sdkVersionDir(version)

        if (isValidGitRepo(target)) {
            LOG.info("SDK '$version' already installed at ${target.absolutePath}")
            return true
        }

        return try {
            // Ensure versions directory exists
            versionsDir().mkdirs()

            indicator?.text = "Cloning Flutter SDK '$version'..."
            runGit("clone", Constants.FLUTTER_GIT_URL, target.absolutePath)

            indicator?.text = "Checking out '$version'..."
            runGitIn(target, "checkout", version)

            indicator?.text = "Caching Flutter SDK artifacts..."
            val flutterBin = File(target, "bin/flutter").absolutePath
            val pubCache = File(target, ".pub-cache").absolutePath
            val cmd = GeneralCommandLine(flutterBin, "--version")
                .withWorkDirectory(target)
                .withEnvironment("PUB_CACHE", pubCache)
                .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
            val handler = CapturingProcessHandler(cmd)
            handler.runProcess(300_000)

            // Auto-set global if no global version exists
            if (getGlobalSdkVersion() == null) {
                RcConfig.writeValue(Constants.GLOBAL_SDK_KEY, version)
                ShellConfig.updatePath(target.absolutePath, pubCache)
                updateDefaultSdkLink(target)
            }

            true
        } catch (e: Exception) {
            LOG.warn("Failed to install SDK '$version'", e)
            // Clean up partial install
            if (target.exists()) {
                target.deleteRecursively()
            }
            false
        }
    }

    override fun removeSdk(version: String): Boolean {
        val sdkDir = sdkVersionDir(version)
        if (!sdkDir.exists()) {
            LOG.warn("SDK '$version' not installed")
            return false
        }

        return try {
            sdkDir.deleteRecursively()

            // Clear global config and shell PATH if this was the global version
            val globalVersion = RcConfig.readValue(Constants.GLOBAL_SDK_KEY)?.trim()
            if (globalVersion == version) {
                RcConfig.removeKey(Constants.GLOBAL_SDK_KEY)
                ShellConfig.removePath()
                removeDefaultSdkLink()
            }

            true
        } catch (e: Exception) {
            LOG.warn("Failed to remove SDK '$version'", e)
            false
        }
    }

    override fun pinToProject(version: String, projectPath: String): Boolean {
        val sdkPath = getSdkPath(version) ?: run {
            LOG.warn("Cannot pin: SDK '$version' is not installed")
            return false
        }
        if (!isFlutterSdk(File(sdkPath))) {
            LOG.warn("Cannot pin: SDK '$version' is not a valid Flutter SDK")
            return false
        }
        return try {
            File(projectPath, Constants.FLUTTER_VERSION_FILE).writeText("${version.trim()}\n")
            true
        } catch (e: Exception) {
            LOG.warn("Failed to pin SDK '$version' to project", e)
            false
        }
    }

    override fun unpinFromProject(projectPath: String): Boolean {
        val fvFile = File(projectPath, Constants.FLUTTER_VERSION_FILE)
        if (!fvFile.exists()) return true // already unpinned
        return try {
            fvFile.delete()
        } catch (e: Exception) {
            LOG.warn("Failed to unpin SDK from project", e)
            false
        }
    }

    override fun getSdkPath(version: String): String? {
        val trimmed = version.trim()
        val sdkDir = sdkVersionDir(trimmed)
        if (sdkDir.exists()) return sdkDir.absolutePath

        // Fallback: scan versions dir for a directory whose trimmed name matches.
        // When found, rename to the canonical name so trailing whitespace doesn't
        // leak into shell config files.
        val vDir = versionsDir()
        if (vDir.exists()) {
            vDir.listFiles()?.forEach { dir ->
                if (dir.isDirectory && dir.name.trim() == trimmed && dir.name != trimmed) {
                    return try {
                        dir.renameTo(sdkDir)
                        sdkDir.absolutePath
                    } catch (_: Exception) {
                        dir.absolutePath // rename failed — return raw path
                    }
                }
            }
        }

        if (trimmed == Constants.COMPILED_VERSION) {
            val compiledDir = File(homeDir(), Constants.COMPILED_SDK_REL)
            if (compiledDir.exists()) return compiledDir.absolutePath
        }

        return null
    }

    override fun isSdkInstalled(version: String): Boolean {
        val sdkPath = getSdkPath(version) ?: return false
        return isFlutterSdk(File(sdkPath))
    }

    private fun isValidGitRepo(dir: File): Boolean {
        return dir.exists() && File(dir, Constants.GIT_HEAD_FILE).exists()
    }

    /**
     * Returns true if [dir] contains a usable Flutter SDK (`bin/flutter`).
     *
     * Less strict than [isValidGitRepo] — works for SDKs installed from
     * release archives or where `.git` was cleaned up.
     */
    private fun isFlutterSdk(dir: File): Boolean {
        val osName = System.getProperty(Constants.SYS_OS_NAME, "").lowercase()
        val flutter = if (osName.contains(Constants.OS_WINDOWS_MARKER)) {
            File(dir, "bin${File.separator}flutter.bat")
        } else {
            File(dir, "bin${File.separator}flutter")
        }
        return flutter.exists()
    }

    private fun runGit(vararg args: String) {
        val cmd = GeneralCommandLine(Constants.CMD_GIT, *args)
            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
        val handler = CapturingProcessHandler(cmd)
        val result = handler.runProcess(300_000)
        if (result.exitCode != 0) {
            throw RuntimeException("git ${args.joinToString(" ")} failed: ${result.stderr}")
        }
    }

    private fun runGitIn(dir: File, vararg args: String) {
        val cmd = GeneralCommandLine(Constants.CMD_GIT, *args)
            .withWorkDirectory(dir)
            .withParentEnvironmentType(GeneralCommandLine.ParentEnvironmentType.CONSOLE)
        val handler = CapturingProcessHandler(cmd)
        val result = handler.runProcess(300_000)
        if (result.exitCode != 0) {
            throw RuntimeException("git ${args.joinToString(" ")} failed: ${result.stderr}")
        }
    }
}
