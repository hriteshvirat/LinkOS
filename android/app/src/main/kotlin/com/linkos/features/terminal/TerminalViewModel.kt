package com.linkos.features.terminal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.json.JSONObject
import javax.inject.Inject

@HiltViewModel
class TerminalViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _terminalOutput = MutableStateFlow("LinkOS PTY Terminal v1.0\nReady.\n")
    val terminalOutput: StateFlow<String> = _terminalOutput.asStateFlow()

    private var activeSessionId = "default_session"

    init {
        viewModelScope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                try {
                    val text = String(bytes, Charsets.UTF_8)
                    if (text.startsWith("{")) {
                        val envelope = JSONObject(text)
                        if (envelope.optString("channel") == "terminal") {
                            val payloadText = envelope.optString("payload")
                            if (payloadText.startsWith("{")) {
                                val obj = JSONObject(payloadText)
                                if (obj.optString("status") == "session_created") {
                                    activeSessionId = obj.optString("session_id")
                                    _terminalOutput.value += "\n[Session Connected: $activeSessionId]\n"
                                    return@collect
                                }
                                if (obj.optString("action") == "output") {
                                    _terminalOutput.value += obj.optString("text")
                                    return@collect
                                }
                            }
                            _terminalOutput.value += payloadText
                        }
                    }
                } catch (e: Exception) {
                    // Ignore
                }
            }
        }
        viewModelScope.launch {
            webSocketClient.state.collect { state ->
                if (state == com.linkos.core.network.ConnectionState.CONNECTED) {
                    _terminalOutput.value += "\n[Reconnecting Terminal Session...]\n"
                    startSession()
                }
            }
        }
        startSession()
    }

    fun startSession() {
        val payload = buildJsonObject {
            put("action", "start")
        }.toString()
        webSocketClient.sendEnvelope("terminal", payload, type = "request")
    }

    fun sendInput(text: String) {
        val payload = buildJsonObject {
            put("action", "input")
            put("session_id", activeSessionId)
            put("text", text)
        }.toString()
        webSocketClient.sendEnvelope("terminal", payload, type = "request")
    }

    fun sendSignal(signal: Int) {
        val payload = buildJsonObject {
            put("action", "signal")
            put("session_id", activeSessionId)
            put("signal", signal)
        }.toString()
        webSocketClient.sendEnvelope("terminal", payload, type = "request")
    }

    fun clearTerminal() {
        _terminalOutput.value = ""
    }
}
