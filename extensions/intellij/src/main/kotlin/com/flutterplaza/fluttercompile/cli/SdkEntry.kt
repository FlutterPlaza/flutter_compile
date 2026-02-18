package com.flutterplaza.fluttercompile.cli

/** Installed SDK entry returned by `flutter_compile sdk list --json`. */
data class SdkEntry(
    val version: String,
    val path: String,
    val global: Boolean,
    val project: Boolean,
    val contributor: Boolean,
) {
    /** Display label for UI elements. */
    fun displayLabel(): String = buildString {
        append(version)
        val markers = mutableListOf<String>()
        if (global) markers.add("global")
        if (project) markers.add("project")
        if (markers.isNotEmpty()) {
            append(" (${markers.joinToString(", ")})")
        }
    }
}
