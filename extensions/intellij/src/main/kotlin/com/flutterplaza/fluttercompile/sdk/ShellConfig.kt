package com.flutterplaza.fluttercompile.sdk

import com.flutterplaza.fluttercompile.Constants
import com.intellij.openapi.diagnostic.Logger
import java.io.File

/**
 * Manages the SDK manager PATH block in the user's shell config
 * (~/.zshrc, ~/.bashrc, ~/.profile, or PowerShell profile on Windows).
 *
 * Mirrors the exact logic used by the flutter_compile CLI so that
 * SDK switches from the IDE produce the same shell environment as
 * `fcp sdk global <version>`.
 */
object ShellConfig {

    private val LOG = Logger.getInstance(ShellConfig::class.java)

    private val SDK_PATH_BLOCK_RE = Regex(
        """\n?# >>> Added by flutter_compile SDK manager >>>[\s\S]*?# <<< Added by flutter_compile SDK manager <<<\n?"""
    )

    /** Regex to detect the source line already present in shell RC. */
    private val SOURCE_LINE_RE = Regex(
        """\n?\[ *-f *~/\.flutter_compile_env *] *&& *source *~/\.flutter_compile_env\n?"""
    )

    private val SOURCE_LINE_WINDOWS_RE = Regex(
        """\n?if \(Test-Path "\${'$'}HOME\\\.flutter_compile_env"\) \{ \. "\${'$'}HOME\\\.flutter_compile_env" }\n?"""
    )

    /** Detect the shell config file for the current platform/user. */
    private fun shellConfigFile(): File {
        val home = System.getProperty(Constants.SYS_USER_HOME)
        val osName = System.getProperty(Constants.SYS_OS_NAME, "").lowercase()

        if (osName.contains(Constants.OS_WINDOWS_MARKER)) {
            val userProfile = System.getenv("USERPROFILE") ?: home
            return File(
                userProfile,
                "Documents${File.separator}WindowsPowerShell${File.separator}Microsoft.PowerShell_profile.ps1"
            )
        }

        val shell = System.getenv(Constants.SHELL_ENV_KEY) ?: ""
        val rc = when {
            shell.contains("bash") -> Constants.SHELL_RC_BASH
            shell.contains("zsh") -> Constants.SHELL_RC_ZSH
            else -> Constants.SHELL_RC_PROFILE
        }
        return File(home, rc)
    }

    /** Returns the dedicated env file path (~/.flutter_compile_env). */
    private fun envFile(): File {
        val home = System.getProperty(Constants.SYS_USER_HOME)
        return File(home, Constants.ENV_FILE)
    }

    /** Whether the current platform is Windows. */
    private fun isWindows(): Boolean {
        return System.getProperty(Constants.SYS_OS_NAME, "").lowercase().contains(Constants.OS_WINDOWS_MARKER)
    }

    /**
     * Idempotently ensure the shell RC has a `source` line for the env file.
     * Also strips any legacy SDK manager PATH blocks from the shell RC as migration.
     */
    fun ensureSourceLine() {
        try {
            val configFile = shellConfigFile()
            var contents = if (configFile.exists()) configFile.readText() else ""
            var changed = false

            // Migration: remove old SDK manager blocks from shell RC
            if (SDK_PATH_BLOCK_RE.containsMatchIn(contents)) {
                contents = contents.replace(SDK_PATH_BLOCK_RE, "")
                changed = true
            }

            // Add source line if not already present
            val sourceLineRe = if (isWindows()) SOURCE_LINE_WINDOWS_RE else SOURCE_LINE_RE
            if (!sourceLineRe.containsMatchIn(contents)) {
                contents += if (isWindows()) Constants.SOURCE_LINE_WINDOWS else Constants.SOURCE_LINE
                changed = true
            }

            if (changed) {
                configFile.parentFile?.mkdirs()
                configFile.writeText(contents)
            }
        } catch (e: Exception) {
            LOG.warn("Failed to ensure source line in shell RC", e)
        }
    }

    /** Build the SDK PATH export block with FLUTTER_COMPILE_SDK guard. */
    private fun buildPathBlock(sdkPath: String, pubCachePath: String): String {
        return if (isWindows()) {
            "\n${Constants.SDK_PATH_BLOCK_START}\n" +
                "if (-not \$env:FLUTTER_COMPILE_SDK) {\n" +
                "  \$env:PATH = \"${sdkPath}\\bin;\$env:PATH\"\n" +
                "  \$env:PATH = \"${sdkPath}\\bin\\cache\\dart-sdk\\bin;\$env:PATH\"\n" +
                "  \$env:PUB_CACHE = \"${pubCachePath}\"\n" +
                "} else {\n" +
                "  \$env:PATH = \"\$env:FLUTTER_COMPILE_SDK\\bin;\$env:FLUTTER_COMPILE_SDK\\bin\\cache\\dart-sdk\\bin;\$env:PATH\"\n" +
                "  \$env:PUB_CACHE = \"\$env:FLUTTER_COMPILE_SDK\\.pub-cache\"\n" +
                "}\n" +
                "${Constants.SDK_PATH_BLOCK_END}\n"
        } else {
            "\n${Constants.SDK_PATH_BLOCK_START}\n" +
                "if [ -z \"\$FLUTTER_COMPILE_SDK\" ]; then\n" +
                "  export PATH=${sdkPath}/bin:\$PATH\n" +
                "  export PATH=${sdkPath}/bin/cache/dart-sdk/bin:\$PATH\n" +
                "  export PUB_CACHE=${pubCachePath}\n" +
                "else\n" +
                "  export PATH=\"\$FLUTTER_COMPILE_SDK/bin:\$FLUTTER_COMPILE_SDK/bin/cache/dart-sdk/bin:\$PATH\"\n" +
                "  export PUB_CACHE=\"\$FLUTTER_COMPILE_SDK/.pub-cache\"\n" +
                "fi\n" +
                "${Constants.SDK_PATH_BLOCK_END}\n"
        }
    }

    /**
     * Write the SDK PATH block into the env file,
     * replacing any existing flutter_compile SDK manager block.
     * Also ensures the shell RC has the source line.
     */
    fun updatePath(sdkPath: String, pubCachePath: String) {
        try {
            ensureSourceLine()

            val envF = envFile()
            var contents = if (envF.exists()) envF.readText() else ""

            // Remove existing block
            contents = contents.replace(SDK_PATH_BLOCK_RE, "")

            // Append new block
            contents += buildPathBlock(sdkPath, pubCachePath)

            envF.parentFile?.mkdirs()
            envF.writeText(contents)

            LOG.info("Updated env file ${envF.absolutePath} with SDK path $sdkPath")
        } catch (e: Exception) {
            LOG.warn("Failed to update env file with SDK path", e)
        }
    }

    /**
     * Migrate the env file: rewrite old-style SDK blocks with the new
     * FLUTTER_COMPILE_SDK-guarded template. No-op if already migrated.
     *
     * Called once on project open so that existing users get the
     * project-pin fix without having to re-set their global SDK.
     */
    fun migrateBlock() {
        try {
            val envF = envFile()
            if (!envF.exists()) return

            val contents = envF.readText()

            // Nothing to migrate if no SDK block or already guarded
            if (!SDK_PATH_BLOCK_RE.containsMatchIn(contents) || contents.contains("FLUTTER_COMPILE_SDK")) return

            // Resolve the global SDK to rewrite the block with the new template
            val globalVersion = RcConfig.readValue(Constants.GLOBAL_SDK_KEY)?.trim()
            if (globalVersion.isNullOrEmpty()) return

            val home = System.getProperty(Constants.SYS_USER_HOME)
            val sdkDir = File(home, "${Constants.SDK_VERSIONS_REL}${File.separator}$globalVersion")
            if (!sdkDir.exists()) return

            val pubCachePath = File(sdkDir, ".pub-cache").absolutePath
            updatePath(sdkDir.absolutePath, pubCachePath)

            LOG.info("Migrated env file SDK block to guarded template")
        } catch (e: Exception) {
            LOG.warn("Failed to migrate env file SDK block", e)
        }
    }

    /**
     * Remove the SDK PATH block from the env file.
     * Also strips any legacy blocks from the shell RC as migration.
     */
    fun removePath() {
        try {
            // Clean env file
            val envF = envFile()
            if (envF.exists()) {
                var contents = envF.readText()
                contents = contents.replace(SDK_PATH_BLOCK_RE, "")
                envF.writeText(contents)
                LOG.info("Removed SDK PATH block from ${envF.absolutePath}")
            }

            // Migration: also strip legacy block from shell RC
            val configFile = shellConfigFile()
            if (configFile.exists()) {
                var contents = configFile.readText()
                if (SDK_PATH_BLOCK_RE.containsMatchIn(contents)) {
                    contents = contents.replace(SDK_PATH_BLOCK_RE, "")
                    configFile.writeText(contents)
                }
            }
        } catch (e: Exception) {
            LOG.warn("Failed to remove SDK PATH block", e)
        }
    }
}
