package com.flutterplaza.fluttercompile.settings

import com.flutterplaza.fluttercompile.Constants
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage

@Service(Service.Level.APP)
@State(name = Constants.SETTINGS_STATE_NAME, storages = [Storage(Constants.SETTINGS_STORAGE_FILE)])
class FlutterCompileSettings : PersistentStateComponent<FlutterCompileSettings.State> {

    data class State(
        var cliPath: String = Constants.CLI_DEFAULT_PATH,
        var sdkManager: String = Constants.MODE_NATIVE,
    )

    private var myState = State()

    var cliPath: String
        get() = myState.cliPath
        set(value) { myState.cliPath = value }

    var sdkManager: String
        get() = myState.sdkManager
        set(value) { myState.sdkManager = value }

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    companion object {
        fun getInstance(): FlutterCompileSettings =
            ApplicationManager.getApplication().getService(FlutterCompileSettings::class.java)
    }
}
