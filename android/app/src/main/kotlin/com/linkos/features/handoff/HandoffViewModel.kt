package com.linkos.features.handoff

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

@HiltViewModel
class HandoffViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val connectionStateManager: ConnectionStateManager
) : ViewModel(), ConnectionStateSubscriber {

    override val subscriberId = "handoff_view_model"

    private val _lastHandoffUrl = MutableStateFlow<String?>(null)
    val lastHandoffUrl: StateFlow<String?> = _lastHandoffUrl.asStateFlow()

    init {
        connectionStateManager.subscribe(this)
    }

    fun handoffUrlToMac(url: String) {
        val payload = JSONObject().apply {
            put("url", url)
        }.toString()
        
        viewModelScope.launch {
            connectionStateManager.routeMessage(
                channel = MessageChannel.HANDOFF,
                payload = payload.toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        }
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.HANDOFF) return
        
        try {
            val text = String(payload, Charsets.UTF_8)
            val json = JSONObject(text)
            val url = json.optString("url", "")
            
            if (url.isNotBlank()) {
                _lastHandoffUrl.value = url
                
                // Launch standard browser intent
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(intent)
                LinkOSLogger.info("Handoff URL opened on Android: $url", "Handoff")
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to process handoff intent: ${e.message}", "Handoff")
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {
        // QoS updates
    }
}
