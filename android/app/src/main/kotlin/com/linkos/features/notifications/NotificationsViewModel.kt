package com.linkos.features.notifications

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

@Serializable
data class MirroredNotification(
    val id: String,
    val appName: String,
    val title: String,
    val subtitle: String? = null,
    val body: String,
    val timestampMs: Long
)

@HiltViewModel
class NotificationsViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _notifications = MutableStateFlow<List<MirroredNotification>>(emptyList())
    val notifications: StateFlow<List<MirroredNotification>> = _notifications.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    init {
        viewModelScope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                try {
                    val text = String(bytes, Charsets.UTF_8)
                    if (text.startsWith("{")) {
                        val envelope = JSONObject(text)
                        if (envelope.optString("type") == "event" && envelope.optString("channel") == "notifications") {
                            val payloadText = envelope.optString("payload")
                            val notif = json.decodeFromString<MirroredNotification>(payloadText)
                            val current = _notifications.value.toMutableList()
                            current.removeAll { it.id == notif.id }
                            current.add(0, notif)
                            _notifications.value = current
                        }
                    }
                } catch (e: Exception) {
                    // Ignore
                }
            }
        }
    }

    fun dismissNotification(id: String) {
        _notifications.value = _notifications.value.filter { it.id != id }
        val payload = buildJsonObject {
            put("action", "dismiss")
            put("id", id)
        }.toString()
        webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
    }

    fun replyNotification(id: String, replyText: String) {
        val payload = buildJsonObject {
            put("action", "reply")
            put("id", id)
            put("reply_text", replyText)
        }.toString()
        webSocketClient.send(payload.toByteArray(Charsets.UTF_8))
    }
}
