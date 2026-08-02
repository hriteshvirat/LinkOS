package com.linkos.features.workspace

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.ConnectionPhase
import com.linkos.core.network.PeerDevice
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import kotlinx.serialization.Serializable
import javax.inject.Inject

@Serializable
data class WorkspaceProfileItem(
    val id: String,
    val name: String,
    val description: String,
    val iconName: String,
    val appsCount: Int
)

@HiltViewModel
class WorkspaceViewModel @Inject constructor(
    private val connectionStateManager: ConnectionStateManager
) : ViewModel(), ConnectionStateSubscriber {

    override val subscriberId = "workspace_view_model"

    private val _profiles = MutableStateFlow<List<WorkspaceProfileItem>>(
        listOf(
            WorkspaceProfileItem("dev", "Developer Workspace", "Launches Cursor, Terminal & Docker", "hammer", 3),
            WorkspaceProfileItem("design", "Design Studio", "Launches Figma & Photoshop", "palette", 2),
            WorkspaceProfileItem("focus", "Deep Focus", "Enables Do Not Disturb & Notes", "moon", 1)
        )
    )
    val profiles: StateFlow<List<WorkspaceProfileItem>> = _profiles.asStateFlow()

    private val _appList = MutableStateFlow<List<String>>(emptyList())
    val appList: StateFlow<List<String>> = _appList.asStateFlow()

    private val _cpuLoad = MutableStateFlow(0.0)
    val cpuLoad: StateFlow<Double> = _cpuLoad.asStateFlow()

    private val _ramUsageBytes = MutableStateFlow(0L)
    val ramUsageBytes: StateFlow<Long> = _ramUsageBytes.asStateFlow()

    private val _ramTotalBytes = MutableStateFlow(1L)
    val ramTotalBytes: StateFlow<Long> = _ramTotalBytes.asStateFlow()

    init {
        connectionStateManager.subscribe(this)
        queryAppsList()
    }

    fun triggerQuickAction(command: String) {
        val payload = JSONObject().apply {
            put("action", "quick_action")
            put("command", command)
        }.toString()
        
        viewModelScope.launch {
            connectionStateManager.routeMessage(
                channel = MessageChannel.SESSION,
                payload = payload.toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        }
    }

    fun launchWorkspace(id: String) {
        val payload = JSONObject().apply {
            put("action", "launch_workspace")
            put("workspace_id", id)
        }.toString()
        
        viewModelScope.launch {
            connectionStateManager.routeMessage(
                channel = MessageChannel.SESSION,
                payload = payload.toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        }
    }

    fun queryAppsList() {
        val payload = JSONObject().apply {
            put("action", "query_apps")
        }.toString()
        
        viewModelScope.launch {
            connectionStateManager.routeMessage(
                channel = MessageChannel.SESSION,
                payload = payload.toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        }
    }

    fun launchAppOnMac(appName: String) {
        val payload = JSONObject().apply {
            put("action", "launch_app")
            put("app_name", appName)
        }.toString()
        
        viewModelScope.launch {
            connectionStateManager.routeMessage(
                channel = MessageChannel.SESSION,
                payload = payload.toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        }
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.SESSION) return
        
        try {
            val text = String(payload, Charsets.UTF_8)
            val json = JSONObject(text)
            
            when (json.optString("action")) {
                "apps_list" -> {
                    val arr = json.optJSONArray("apps")
                    val list = mutableListOf<String>()
                    if (arr != null) {
                        for (i in 0 until arr.length()) {
                            list.add(arr.getString(i))
                        }
                    }
                    _appList.value = list
                }
                "telemetry" -> {
                    _cpuLoad.value = json.optDouble("cpu_load", 0.0)
                    _ramUsageBytes.value = json.optLong("ram_used_bytes", 0L)
                    _ramTotalBytes.value = json.optLong("ram_total_bytes", 1L)
                }
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to parse workspace message: ${e.message}", "Workspace")
        }
    }

    override suspend fun onConnectionPhaseChanged(phase: ConnectionPhase, device: PeerDevice?) {
        if (phase == ConnectionPhase.CONNECTED) {
            queryAppsList()
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {
        // QoS updates
    }
}
