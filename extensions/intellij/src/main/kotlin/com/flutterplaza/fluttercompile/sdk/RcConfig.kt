package com.flutterplaza.fluttercompile.sdk

import com.flutterplaza.fluttercompile.Constants
import java.io.File

/** Utility for reading/writing the `~/.flutter_compilerc` config file. */
object RcConfig {

    private fun rcFile(): File = File(System.getProperty(Constants.SYS_USER_HOME), Constants.RC_FILE)

    /** Read all key-value pairs from the rc config. */
    fun readAll(): Map<String, String> {
        val file = rcFile()
        if (!file.exists()) return emptyMap()
        val map = linkedMapOf<String, String>()
        file.readLines().forEach { line ->
            val colonIndex = line.indexOf(':')
            if (colonIndex != -1) {
                map[line.substring(0, colonIndex)] = line.substring(colonIndex + 1)
            }
        }
        return map
    }

    /** Read a single value by key. */
    fun readValue(key: String): String? {
        val file = rcFile()
        if (!file.exists()) return null
        file.readLines().forEach { line ->
            val colonIndex = line.indexOf(':')
            if (colonIndex != -1 && line.substring(0, colonIndex) == key) {
                return line.substring(colonIndex + 1)
            }
        }
        return null
    }

    /** Write a key-value pair, preserving existing entries. */
    fun writeValue(key: String, value: String) {
        val map = readAll().toMutableMap()
        map[key] = value
        val content = map.entries.joinToString("\n") { "${it.key}:${it.value}" } + "\n"
        rcFile().writeText(content)
    }

    /** Remove a key from the rc config. */
    fun removeKey(key: String) {
        val file = rcFile()
        if (!file.exists()) return
        val filtered = file.readLines().filter { line ->
            val colonIndex = line.indexOf(':')
            colonIndex == -1 || line.substring(0, colonIndex) != key
        }
        file.writeText(filtered.joinToString("\n") + "\n")
    }
}
