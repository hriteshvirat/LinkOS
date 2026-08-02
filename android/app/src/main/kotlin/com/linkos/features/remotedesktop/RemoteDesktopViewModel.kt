package com.linkos.features.remotedesktop

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize
import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject

@HiltViewModel
class RemoteDesktopViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming.asStateFlow()

    private val _fps = MutableStateFlow(60)
    val fps: StateFlow<Int> = _fps.asStateFlow()

    private val _frameBitmap = MutableStateFlow<Bitmap?>(null)
    val frameBitmap: StateFlow<Bitmap?> = _frameBitmap.asStateFlow()

    private val _connectionProgress = MutableStateFlow("")
    val connectionProgress: StateFlow<String> = _connectionProgress.asStateFlow()

    private val _connectionTimeout = MutableStateFlow(false)
    val connectionTimeout: StateFlow<Boolean> = _connectionTimeout.asStateFlow()

    private var collectJob: Job? = null
    private var timeoutJob: Job? = null
    private var lastDecodeTimeMs: Long = 0L

    init {
        viewModelScope.launch {
            webSocketClient.state.collect { state ->
                if (state == com.linkos.core.network.ConnectionState.DISCONNECTED) {
                    _isStreaming.value = false
                    _frameBitmap.value = null
                } else if (state == com.linkos.core.network.ConnectionState.CONNECTED) {
                    startRemoteSession()
                }
            }
        }
    }

    fun startRemoteSession() {
        _connectionTimeout.value = false
        _frameBitmap.value = null
        _isStreaming.value = false
        
        collectJob?.cancel()
        collectJob = viewModelScope.launch(kotlinx.coroutines.Dispatchers.Default) {
            _connectionProgress.value = "Connecting..."
            delay(400)
            _connectionProgress.value = "Authenticating..."
            delay(400)
            _connectionProgress.value = "Starting Screen Capture..."
            
            val payload = buildJsonObject {
                put("action", "start")
                put("quality", "adaptive")
            }.toString()
            webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
            
            _connectionProgress.value = "Waiting for Frames..."
            
            // Start 8 seconds timeout
            timeoutJob?.cancel()
            timeoutJob = launch(kotlinx.coroutines.Dispatchers.Default) {
                delay(8000)
                if (_frameBitmap.value == null) {
                    _connectionTimeout.value = true
                    _connectionProgress.value = "Connection Timed Out"
                }
            }

            webSocketClient.messageFlow.collect { bytes ->
                if (bytes.isNotEmpty() && bytes[0] == '{'.toByte()) {
                    try {
                        val text = String(bytes, Charsets.UTF_8)
                        val json = org.json.JSONObject(text)
                        if (json.optString("status") == "waiting_for_permission") {
                            timeoutJob?.cancel()
                            timeoutJob = launch(kotlinx.coroutines.Dispatchers.Default) {
                                delay(60000) // 1 minute timeout for user settings permission flow
                                if (_frameBitmap.value == null) {
                                    _connectionTimeout.value = true
                                    _connectionProgress.value = "Permission Timeout"
                                }
                            }
                            _connectionProgress.value = "Waiting for Screen Recording Permission on Mac..."
                        }
                    } catch (e: Exception) {
                        // Ignore
                    }
                } else if (bytes.size > 3 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()) {
                    // Throttle frame decoding to max ~30 FPS to reduce GC allocation pressure
                    val now = System.currentTimeMillis()
                    if (now - lastDecodeTimeMs < 33L) return@collect
                    lastDecodeTimeMs = now

                    try {
                        val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                        if (bmp != null) {
                            timeoutJob?.cancel()
                            _frameBitmap.value = bmp
                            _isStreaming.value = true
                            _connectionProgress.value = "Connected"
                        }
                    } catch (e: OutOfMemoryError) {
                        // Scoped OOM guard: BitmapFactory can throw OutOfMemoryError on large frames.
                        // Log diagnostic info to investigate underlying memory pressure.
                        com.linkos.core.logging.LinkOSLogger.error(
                            "[RemoteDesktop] OutOfMemoryError decoding frame (${bytes.size} bytes). Skipping frame. Investigate memory pressure.",
                            "RemoteDesktop"
                        )
                    } catch (e: Exception) {
                        // ignore decode errors for individual frames
                    }
                }
            }
        }
    }

    fun stopRemoteSession() {
        collectJob?.cancel()
        timeoutJob?.cancel()
        val payload = buildJsonObject {
            put("action", "stop")
        }.toString()
        webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
        _isStreaming.value = false
        _frameBitmap.value = null
        _connectionProgress.value = ""
    }

    fun sendMove(dx: Float, dy: Float) {
        val payload = buildJsonObject {
            put("action", "move")
            put("dx", dx.toDouble())
            put("dy", dy.toDouble())
        }.toString()
        
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendClick(button: String = "left") {
        val payload = buildJsonObject {
            put("action", "click")
            put("button", button)
        }.toString()
        webSocketClient.sendEnvelope("trackpad", payload)
    }

    fun sendScroll(dx: Int, dy: Int) {
        val payload = buildJsonObject {
            put("action", "scroll")
            put("dx", dx)
            put("dy", dy)
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

    fun sendGesture(gesture: String) {
        val payload = buildJsonObject {
            put("action", gesture)
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
