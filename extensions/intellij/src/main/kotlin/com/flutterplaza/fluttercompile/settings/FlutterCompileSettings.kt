package com.flutterplaza.fluttercompile.settings

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage

@Service(Service.Level.APP)
@State(name = "FlutterCompileSettings", storages = [Storage("FlutterCompilePlugin.xml")])
class FlutterCompileSettings : PersistentStateComponent<FlutterCompileSettings.State> {

    data class State(
        var cliPath: String = "flutter_compile",
    )

    private var myState = State()

    var cliPath: String
        get() = myState.cliPath
        set(value) { myState.cliPath = value }

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    companion object {
        fun getInstance(): FlutterCompileSettings =
            ApplicationManager.getApplication().getService(FlutterCompileSettings::class.java)
    }
}
