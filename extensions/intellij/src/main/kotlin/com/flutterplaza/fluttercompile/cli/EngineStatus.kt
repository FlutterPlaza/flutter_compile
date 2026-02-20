package com.flutterplaza.fluttercompile.cli

/** A single engine build entry. */
data class BuildEntry(val name: String, val size: String)

/** Engine status returned by `flutter_compile status --json`. */
data class EngineStatus(
    val configured: Boolean,
    val engine_path: String? = null,
    val source_dir: String? = null,
    val source_exists: Boolean? = null,
    val host_cpu: String? = null,
    val builds: List<BuildEntry>? = null,
    val flutter_project: Boolean? = null,
)
