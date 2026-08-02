package com.linkos.features.ai

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

data class ChatMessage(
    val id: String = java.util.UUID.randomUUID().toString(),
    val sender: String,
    val text: String,
    val timestampMs: Long = System.currentTimeMillis()
)

@HiltViewModel
class AIViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _chatMessages = MutableStateFlow<List<ChatMessage>>(
        listOf(
            ChatMessage(sender = "Mac AI", text = "Hello! I am your LinkOS Mac AI Agent. How can I help automation on your Mac today?")
        )
    )
    val chatMessages: StateFlow<List<ChatMessage>> = _chatMessages.asStateFlow()

    private val _selectedProvider = MutableStateFlow("Local (CoreML)")
    val selectedProvider: StateFlow<String> = _selectedProvider.asStateFlow()

    init {
        viewModelScope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                try {
                    val text = String(bytes, Charsets.UTF_8)
                    if (text.startsWith("{")) {
                        val envelope = JSONObject(text)
                        if (envelope.optString("channel") == "ai") {
                            val payloadText = envelope.optString("payload")
                            val responseJson = JSONObject(payloadText)
                            val aiResponseText = responseJson.optString("text")
                            if (aiResponseText.isNotEmpty()) {
                                addMessage("Mac AI", aiResponseText)
                            }
                        }
                    }
                } catch (e: Exception) {
                    // Ignore
                }
            }
        }
    }

    fun sendPrompt(prompt: String) {
        if (prompt.isBlank()) return
        addMessage("You", prompt)
        webSocketClient.sendEnvelope("ai", prompt, type = "request")
    }

    fun setProvider(provider: String) {
        _selectedProvider.value = provider
    }

    private fun addMessage(sender: String, text: String) {
        _chatMessages.value = _chatMessages.value + ChatMessage(sender = sender, text = text)
    }
}
