package com.linkos.features.workspace

import android.os.Build
import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject

@HiltViewModel
class TabletViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _isSecondDisplayActive = MutableStateFlow(false)
    val isSecondDisplayActive: StateFlow<Boolean> = _isSecondDisplayActive.asStateFlow()

    private val _isXiaomiTablet = MutableStateFlow(checkIfXiaomiTablet())
    val isXiaomiTablet: StateFlow<Boolean> = _isXiaomiTablet.asStateFlow()

    fun toggleSecondDisplay(mode: String = "Extend Desktop") {
        val newState = !_isSecondDisplayActive.value
        _isSecondDisplayActive.value = newState
        val payload = buildJsonObject {
            put("action", if (newState) "enable_second_display" else "disable_second_display")
            put("mode", mode)
        }.toString()
        webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
    }

    fun sendStylusStroke(x: Float, y: Float, pressure: Float, tiltX: Float, tiltY: Float) {
        val payload = buildJsonObject {
            put("action", "stylus_input")
            put("x", x.toDouble())
            put("y", y.toDouble())
            put("pressure", pressure.toDouble())
            put("tiltX", tiltX.toDouble())
            put("tiltY", tiltY.toDouble())
        }.toString()
        webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
    }

    private fun checkIfXiaomiTablet(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        return (manufacturer.contains("xiaomi") || brand.contains("xiaomi") || brand.contains("redmi"))
    }
}
