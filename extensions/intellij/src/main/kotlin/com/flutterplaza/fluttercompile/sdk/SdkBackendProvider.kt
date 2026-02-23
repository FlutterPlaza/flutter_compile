package com.flutterplaza.fluttercompile.sdk

import com.flutterplaza.fluttercompile.Constants
import com.flutterplaza.fluttercompile.settings.FlutterCompileSettings

/** Returns the active SDK backend based on the `sdkManager` setting. */
object SdkBackendProvider {

    private var cachedMode: String? = null
    private var cachedBackend: SdkBackend? = null

    fun get(): SdkBackend {
        val mode = FlutterCompileSettings.getInstance().sdkManager
        if (cachedBackend != null && cachedMode == mode) {
            return cachedBackend!!
        }
        cachedMode = mode
        cachedBackend = when (mode) {
            Constants.MODE_FVM -> FvmSdkBackend()
            else -> NativeSdkBackend()
        }
        return cachedBackend!!
    }

    /** Force-reload after settings change. */
    fun reload() {
        cachedBackend = null
        cachedMode = null
    }
}
