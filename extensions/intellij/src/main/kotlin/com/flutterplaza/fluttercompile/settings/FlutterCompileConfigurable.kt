package com.flutterplaza.fluttercompile.settings

import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.ui.DialogPanel
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel

class FlutterCompileConfigurable : BoundConfigurable("Flutter Compile") {
    private val settings = FlutterCompileSettings.getInstance()

    override fun createPanel(): DialogPanel = panel {
        row("CLI path:") {
            textField()
                .bindText(settings::cliPath)
                .comment("Path to the flutter_compile executable. Default: flutter_compile (uses PATH).")
        }
    }
}
