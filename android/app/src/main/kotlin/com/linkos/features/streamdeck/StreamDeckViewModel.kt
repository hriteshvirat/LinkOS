package com.linkos.features.streamdeck

import android.content.Context
import androidx.lifecycle.ViewModel
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.json.JSONObject
import javax.inject.Inject

@Serializable
data class StreamButton(
    val id: String,
    val label: String,
    val iconName: String,
    @kotlinx.serialization.SerialName("backgroundColorHex") val colorHex: String,
    val actionType: String,
    @kotlinx.serialization.SerialName("actionPayload") val actionParams: Map<String, String> = emptyMap(),
    // iconType defaults to "sfSymbol" for backward compatibility with older macOS versions
    // that don't send this field. Possible values: "sfSymbol", "emoji", "material"
    val iconType: String = "sfSymbol"
)

@Serializable
data class StreamDeckGridPayload(
    val id: String,
    val name: String,
    val columns: Int,
    val rows: Int,
    val buttons: List<StreamButton>
)

@HiltViewModel
class StreamDeckViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient,
    private val connectionStateManager: ConnectionStateManager,
    @ApplicationContext private val context: Context
) : ViewModel(), ConnectionStateSubscriber {

    override val subscriberId = "android_stream_deck_view_model"

    private val jsonDecoder = Json { ignoreUnknownKeys = true }

    private val _buttons = MutableStateFlow<List<StreamButton>>(
        listOf(
            StreamButton("b1", "Mute Volume", "volume_off", "#EF4444", "SYSTEM_CONTROL", mapOf("setting" to "mute")),
            StreamButton("b2", "Screenshot", "camera", "#3B82F6", "TAKE_SCREENSHOT"),
            StreamButton("b3", "Open Chrome", "public", "#8B5CF6", "LAUNCH_APP", mapOf("app_name" to "Google Chrome")),
            StreamButton("b4", "Downloads", "folder", "#10B981", "OPEN_FOLDER", mapOf("path" to "~/Downloads")),
            StreamButton("b5", "Terminal", "terminal", "#F59E0B", "LAUNCH_APP", mapOf("app_name" to "Terminal")),
            StreamButton("b6", "Lock Mac", "lock", "#6B7280", "SYSTEM_CONTROL", mapOf("setting" to "lock")),
            StreamButton("b7", "Play/Pause", "play_arrow", "#EC4899", "SYSTEM_CONTROL", mapOf("setting" to "playpause")),
            StreamButton("b8", "Empty Macro", "add_circle", "#4B5563", "NONE"),
            StreamButton("b9", "Empty Macro", "add_circle", "#4B5563", "NONE")
        )
    )
    val buttons: StateFlow<List<StreamButton>> = _buttons.asStateFlow()

    init {
        connectionStateManager.subscribe(this)
        loadSavedGrid()
    }

    private fun loadSavedGrid() {
        try {
            val sharedPrefs = context.getSharedPreferences("linkos_streamdeck", Context.MODE_PRIVATE)
            val savedJson = sharedPrefs.getString("grid_json", null)
            if (!savedJson.isNullOrEmpty()) {
                val grid = jsonDecoder.decodeFromString<StreamDeckGridPayload>(savedJson)
                _buttons.value = grid.buttons
            }
        } catch (e: Exception) {
            // Fallback to default buttons on error
        }
    }

    fun triggerButton(button: StreamButton) {
        if (button.actionType == "NONE") return
        val payload = buildJsonObject {
            put("action_type", button.actionType)
            val paramsObj = buildJsonObject {
                button.actionParams.forEach { (k, v) -> put(k, v) }
            }
            put("params", paramsObj)
        }.toString()
        webSocketClient.sendEnvelope("streamdeck", payload)
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.AUTOMATION) return
        
        try {
            val text = String(payload, Charsets.UTF_8)
            
            // Try parsing directly as Grid Config first
            var grid: StreamDeckGridPayload? = null
            try {
                grid = jsonDecoder.decodeFromString<StreamDeckGridPayload>(text)
            } catch (e: Exception) {
                // Fallback: Check if it's wrapped or contains action feedback
                val jsonObj = JSONObject(text)
                val payloadText = jsonObj.optString("payload")
                if (payloadText.isNotEmpty()) {
                    try {
                        grid = jsonDecoder.decodeFromString<StreamDeckGridPayload>(payloadText)
                    } catch (ex: Exception) {}
                }
                
                if (jsonObj.has("status")) {
                    val status = jsonObj.optString("status")
                    val message = jsonObj.optString("message")
                    val actionType = jsonObj.optString("action_type")
                    
                    withContext(Dispatchers.Main) {
                        val displayAction = when (actionType) {
                            "TAKE_SCREENSHOT" -> "Screenshot"
                            "LAUNCH_APP" -> "App Launch"
                            "SYSTEM_CONTROL" -> "System Command"
                            "OPEN_FOLDER" -> "Folder Open"
                            else -> actionType
                        }
                        
                        android.widget.Toast.makeText(
                            context,
                            if (status == "success") "Executed: $displayAction" else "Failed: $message",
                            android.widget.Toast.LENGTH_SHORT
                        ).show()
                    }
                }
            }
            
            if (grid != null) {
                withContext(Dispatchers.Main) {
                    _buttons.value = grid.buttons
                }
                try {
                    val sharedPrefs = context.getSharedPreferences("linkos_streamdeck", Context.MODE_PRIVATE)
                    sharedPrefs.edit().putString("grid_json", text).apply()
                } catch (e: Exception) {}
            }
        } catch (e: Exception) {
            // Ignore
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {}
}
