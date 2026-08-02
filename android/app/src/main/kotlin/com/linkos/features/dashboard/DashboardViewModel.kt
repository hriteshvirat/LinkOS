package com.linkos.features.dashboard

import androidx.lifecycle.ViewModel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

@Serializable
data class SystemMetrics(
    val cpuUserPercent: Double = 0.0,
    val cpuSystemPercent: Double = 0.0,
    val cpuIdlePercent: Double = 100.0,
    val memoryTotalBytes: Long = 0L,
    val memoryUsedBytes: Long = 0L,
    val memoryFreeBytes: Long = 0L,
    val batteryPercent: Double = 100.0,
    val isCharging: Boolean = false,
    val isOnACPower: Boolean = false,
    val diskTotalBytes: Long = 0L,
    val diskFreeBytes: Long = 0L,
    val timestampMs: Long = 0L
)

@HiltViewModel
class DashboardViewModel @Inject constructor(
    private val webSocketClient: WebSocketClient
) : ViewModel() {

    private val _metrics = MutableStateFlow(SystemMetrics())
    val metrics: StateFlow<SystemMetrics> = _metrics.asStateFlow()

    private val json = Json { ignoreUnknownKeys = true }

    init {
        viewModelScope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                try {
                    val text = String(bytes, Charsets.UTF_8)
                    if (text.startsWith("{")) {
                        val envelope = JSONObject(text)
                        if (envelope.optString("channel") == "dashboard") {
                            val payloadText = envelope.optString("payload")
                            val parsed = json.decodeFromString<SystemMetrics>(payloadText)
                            _metrics.value = parsed
                        }
                    }
                } catch (e: Exception) {
                    // Ignore
                }
            }
        }
    }
}
