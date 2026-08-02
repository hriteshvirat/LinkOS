package com.linkos.features.trackpad

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject

@HiltViewModel
class TrackpadViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    fun sendMove(dx: Float, dy: Float) {
        val payload = buildJsonObject {
            put("action", "move")
            put("dx", dx.toDouble())
            put("dy", dy.toDouble())
        }.toString()
        
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendClick(button: String = "left", isTap: Boolean = false) {
        try {
            com.linkos.core.logging.LinkOSLogger.info("[Trackpad] ${button.replaceFirstChar { it.uppercase() }} click button pressed (isTap: $isTap)", "Trackpad")
            val payload = buildJsonObject {
                put("action", "click")
                put("button", button)
                put("isTap", isTap)
            }.toString()
            webSocketClient.sendEnvelope("trackpad", payload)
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("[Trackpad] ERROR: Failed to send click: ${e.message}", "Trackpad")
        }
    }

    fun sendScroll(dx: Float, dy: Float) {
        val payload = buildJsonObject {
            put("action", "scroll")
            put("dx", dx.toDouble())
            put("dy", dy.toDouble())
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendGesture(gesture: String) {
        val payload = buildJsonObject {
            put("action", gesture)
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendZoom(scale: Double) {
        val payload = buildJsonObject {
            put("action", "zoom")
            put("scale", scale)
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendLaunchpad() {
        val payload = buildJsonObject {
            put("action", "launchpad")
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendMediaKey(key: String) {
        val payload = buildJsonObject {
            put("action", "media")
            put("key", key)
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendText(text: String) {
        val payload = buildJsonObject {
            put("action", "keyboard")
            put("text", text)
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendSpecialKey(key: String) {
        val payload = buildJsonObject {
            put("action", "keyboard")
            put("key", key)
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }
}
