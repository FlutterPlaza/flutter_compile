package com.flutterplaza.fluttercompile.cli

/** Structured doctor check returned by `flutter_compile doctor --json`. */
data class DoctorCheck(
    val name: String,
    val category: String,
    val status: String,
    val path: String? = null,
    val error: String? = null,
    val missing_remotes: List<String>? = null,
)
