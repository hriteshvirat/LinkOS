package com.linkos.core.network

import com.linkos.core.device.DeviceInfoProvider
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.security.KeystoreManager
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import org.json.JSONObject
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Logical multiplex channels ordered by priority.
 * Lower ordinal = higher priority. Cursor packets must never be blocked.
 */
enum class MessageChannel(val priority: Int) {
    CURSOR(0),
    KEYBOARD(1),
    CLIPBOARD(2),
    FILE_TRANSFER(3),
    REMOTE_DESKTOP(4),
    AUDIO(5),
    CAMERA(6),
    NOTIFICATIONS(7),
    PHONE(8),
    HANDOFF(9),
    MEDIA_CONTROL(10),
    AUTOMATION(11),
    HEARTBEAT(12),
    SESSION(13);

    companion object {
        fun fromString(value: String): MessageChannel? {
            if (value.equals("streamdeck", ignoreCase = true)) return AUTOMATION
            if (value.equals("files", ignoreCase = true)) return FILE_TRANSFER
            return entries.firstOrNull { it.name.equals(value, ignoreCase = true) ||
                    it.name.replace("_", "").equals(value.replace("_", ""), ignoreCase = true) }
        }
    }
}

/**
 * Unified connection phases visible throughout the app.
 */
enum class ConnectionPhase {
    DISCONNECTED,
    DISCOVERING,
    CONNECTING,
    PAIRING,
    CONNECTED,
    RECONNECTING
}

/**
 * Represents a connected peer device.
 */
data class PeerDevice(
    val id: String,
    var name: String,
    var model: String = "",
    var osVersion: String = "",
    var protocolVersion: Int = 1,
    var capabilities: Set<String> = emptySet()
)

/**
 * Quality of Service profiles that adapt streaming/input parameters to current conditions.
 */
enum class QoSProfile {
    OPTIMAL,
    BALANCED,
    DEGRADED,
    POWER_SAVING
}

/**
 * Dynamic QoS state with adaptive evaluation.
 */
data class QoSState(
    var profile: QoSProfile = QoSProfile.OPTIMAL,
    var currentFPS: Int = 60,
    var targetBitrate: Int = 8_000_000, // bits/sec
    var packetLossRate: Double = 0.0,
    var cpuUsage: Double = 0.0,
    var isBatteryLow: Boolean = false,
    var coalescingThresholdMs: Double = 1.0
) {
    fun evaluate(): QoSState {
        return when {
            isBatteryLow -> copy(
                profile = QoSProfile.POWER_SAVING,
                currentFPS = 30,
                targetBitrate = 3_000_000,
                coalescingThresholdMs = 5.0
            )
            currentRTT > 100 || cpuUsage > 0.8 -> copy(
                profile = QoSProfile.DEGRADED,
                currentFPS = 30,
                targetBitrate = 4_000_000,
                coalescingThresholdMs = 3.0
            )
            currentRTT > 50 || packetLossRate > 0.02 -> copy(
                profile = QoSProfile.BALANCED,
                currentFPS = 45,
                targetBitrate = 6_000_000,
                coalescingThresholdMs = 2.0
            )
            else -> copy(
                profile = QoSProfile.OPTIMAL,
                currentFPS = 60,
                targetBitrate = 8_000_000,
                coalescingThresholdMs = 1.0
            )
        }
    }

    private val currentRTT: Long
        get() = 0L // Placeholder
}

/**
 * Subscriber interface for connection state events.
 */
interface ConnectionStateSubscriber {
    val subscriberId: String
    suspend fun onConnectionPhaseChanged(phase: ConnectionPhase, device: PeerDevice?) {}
    suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {}
    suspend fun onResponseReceived(correlationId: String, payload: String, fromDeviceId: String) {}
    suspend fun onQoSChanged(state: QoSState) {}
}

/**
 * Centralized Connection State Manager.
 * All subsystems subscribe here instead of managing their own socket lifecycles.
 * Switching tabs on Android swaps the view layout instantly without socket tear-downs.
 */
@Singleton
class ConnectionStateManager @Inject constructor(
    private val webSocketClient: WebSocketClient,
    private val bonjourClient: BonjourClient,
    private val keystoreManager: KeystoreManager,
    private val deviceInfoProvider: DeviceInfoProvider,
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context
) {

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())


    // Connection phase
    private val _phase = MutableStateFlow(ConnectionPhase.DISCONNECTED)
    val phase: StateFlow<ConnectionPhase> = _phase.asStateFlow()

    // Connected device
    private val _connectedDevice = MutableStateFlow<PeerDevice?>(null)
    val connectedDevice: StateFlow<PeerDevice?> = _connectedDevice.asStateFlow()

    // QoS state
    private val _qos = MutableStateFlow(QoSState())
    val qos: StateFlow<QoSState> = _qos.asStateFlow()

    // Performance counters
    private val _rttMs = MutableStateFlow(0L)
    val rttMs: StateFlow<Long> = _rttMs.asStateFlow()

    private val _reconnectCount = MutableStateFlow(0)
    val reconnectCount: StateFlow<Int> = _reconnectCount.asStateFlow()

    // Battery monitoring
    private val _macBatteryPercent = MutableStateFlow(85)
    val macBatteryPercent: StateFlow<Int> = _macBatteryPercent.asStateFlow()

    private val _isMacCharging = MutableStateFlow(true)
    val isMacCharging: StateFlow<Boolean> = _isMacCharging.asStateFlow()

    private val _isMacOnACPower = MutableStateFlow(false)
    val isMacOnACPower: StateFlow<Boolean> = _isMacOnACPower.asStateFlow()

    private val _androidBatteryPercent = MutableStateFlow(80)
    val androidBatteryPercent: StateFlow<Int> = _androidBatteryPercent.asStateFlow()

    private val _isAndroidCharging = MutableStateFlow(false)
    val isAndroidCharging: StateFlow<Boolean> = _isAndroidCharging.asStateFlow()

    // Subscribers
    private val subscribers = mutableMapOf<String, ConnectionStateSubscriber>()
    private var autoReconnectEnabled = true

    // QoS evaluation job
    private var qosJob: Job? = null

    init {
        startQoSEvaluation()
        startWebSocketRouting()
        
        // Synchronize WebSocketClient connection phase
        scope.launch {
            webSocketClient.state.collect { state ->
                val newPhase = when (state) {
                    ConnectionState.DISCONNECTED -> ConnectionPhase.DISCONNECTED
                    ConnectionState.CONNECTING -> ConnectionPhase.CONNECTING
                    ConnectionState.PAIRING -> ConnectionPhase.PAIRING
                    ConnectionState.CONNECTED -> ConnectionPhase.CONNECTED
                }
                val device = if (state == ConnectionState.CONNECTED) {
                    PeerDevice(
                        id = "mac_host",
                        name = webSocketClient.connectedMacName.value,
                        model = "Macbook",
                        osVersion = "macOS"
                    )
                } else {
                    null
                }
                transition(newPhase, device)
            }
        }

        // Keep connected device name updated if it changes
        scope.launch {
            webSocketClient.connectedMacName.collect { name ->
                if (phase.value == ConnectionPhase.CONNECTED) {
                    updateDeviceName(name)
                }
            }
        }

        // Global background auto-reconnect and device discovery collection.
        // Only auto-reconnects if: paired, disconnected, AND not a manual disconnect.
        var lastConnectAttemptTime = 0L
        scope.launch {
            combine(
                bonjourClient.discoveredServices,
                webSocketClient.state
            ) { discovered, state ->
                Pair(discovered, state)
            }.collect { (discovered, state) ->
                val isPaired = keystoreManager.getString("is_paired") == "true"
                val lastHost = keystoreManager.getString("last_mac_host")
                val lastPort = keystoreManager.getString("last_mac_port")?.toIntOrNull()
                
                // IMPORTANT: check isManualDisconnect and autoReconnectEnabled to suppress auto-reconnect on user-initiated disconnects.
                // Also only perform automatic reconnections when the app is open (foreground).
                if (isPaired && state == ConnectionState.DISCONNECTED && !webSocketClient.isManualDisconnect && autoReconnectEnabled && isAppInForeground()) {
                    val now = System.currentTimeMillis()
                    if (now - lastConnectAttemptTime > 10000L) {
                        lastConnectAttemptTime = now
                        val matchingService = discovered.firstOrNull { it.host == lastHost }
                        if (matchingService != null) {
                            LinkOSLogger.info("[ConnectionManager] Paired device discovered! Auto-connecting...", "ConnectionState")
                            webSocketClient.connect(matchingService.host, matchingService.port, method = "TRUSTED")
                        } else if (!lastHost.isNullOrEmpty() && lastPort != null) {
                            LinkOSLogger.info("[ConnectionManager] Trying last known host directly...", "ConnectionState")
                            webSocketClient.connect(lastHost, lastPort, method = "TRUSTED")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subscription

    fun subscribe(subscriber: ConnectionStateSubscriber) {
        subscribers[subscriber.subscriberId] = subscriber
        LinkOSLogger.debug("Subscriber registered: ${subscriber.subscriberId}", "ConnectionState")
    }

    fun unsubscribe(subscriberId: String) {
        subscribers.remove(subscriberId)
    }

    fun connect(host: String, port: Int, pairingCode: String? = null, method: String? = null) {
        autoReconnectEnabled = true
        webSocketClient.connect(host, port, pairingCode, method)
    }

    private var _wasManualDisconnect = false

    fun disconnect() {
        _wasManualDisconnect = true
        autoReconnectEnabled = false
        webSocketClient.disconnect()
    }

    fun resetManualDisconnect() {
        _wasManualDisconnect = false
        autoReconnectEnabled = false // DO NOT auto-reconnect on "Scan Again"!
        webSocketClient.isManualDisconnect = false
    }

    // MARK: - State Transitions

    fun transition(newPhase: ConnectionPhase, device: PeerDevice? = null) {
        val oldPhase = _phase.value
        _phase.value = newPhase

        if (device != null) {
            _connectedDevice.value = device
        }

        when (newPhase) {
            ConnectionPhase.CONNECTED -> {
                bonjourClient.stopDiscovery()
                bonjourClient.stopAdvertising()
                // Initial battery sync upon successful connection
                updateAndroidBattery(_androidBatteryPercent.value, _isAndroidCharging.value)
            }
            ConnectionPhase.DISCONNECTED -> {
                _connectedDevice.value = null
                bonjourClient.stopDiscovery()
                bonjourClient.stopAdvertising()
                bonjourClient.clearDiscoveredServices()
                if (!_wasManualDisconnect) {
                    val info = deviceInfoProvider.getDeviceInfo()
                    bonjourClient.startAdvertising(info.deviceName, info.deviceId)
                    if (isAppInForeground()) {
                        bonjourClient.startDiscovery()
                    }
                }
            }
            ConnectionPhase.RECONNECTING -> _reconnectCount.value++
            else -> {}
        }

        LinkOSLogger.info("[ConnectionState] ${oldPhase.name} → ${newPhase.name}", "ConnectionState")

        val currentDevice = _connectedDevice.value
        scope.launch {
            notifySubscribers { it.onConnectionPhaseChanged(newPhase, currentDevice) }
        }
    }

    fun updateAndroidBattery(percent: Int, isCharging: Boolean, powerSource: String = "Battery") {
        _androidBatteryPercent.value = percent
        _isAndroidCharging.value = isCharging

        if (webSocketClient.state.value == ConnectionState.CONNECTED) {
            scope.launch {
                try {
                    val payload = JSONObject().apply {
                        put("batteryPercent", percent)
                        put("isCharging", isCharging)
                        put("powerSource", powerSource)
                    }.toString()
                    webSocketClient.sendEnvelope("dashboard", payload, type = "data")
                } catch (e: Exception) {
                    LinkOSLogger.error("Failed to send Android battery update: ${e.message}", "ConnectionState")
                }
            }
        }
    }

    fun updateMacBattery(percent: Int, isCharging: Boolean, isOnACPower: Boolean = false) {
        _macBatteryPercent.value = percent
        _isMacCharging.value = isCharging
        _isMacOnACPower.value = isOnACPower
        scope.launch {
            // Also notify any subscribers of updated telemetry state
            notifySubscribers { it.onQoSChanged(_qos.value) }
        }
    }

    // MARK: - Device Identity

    fun updateDeviceName(name: String) {
        _connectedDevice.value = _connectedDevice.value?.copy(name = name)
        LinkOSLogger.info("[ConnectionState] Device name updated to: $name", "ConnectionState")
    }

    // MARK: - Message Routing

    fun routeMessage(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        scope.launch {
            notifySubscribers { it.onMessageReceived(channel, payload, fromDeviceId) }
        }
    }

    // MARK: - WebSocket Incoming Message collector

    private fun startWebSocketRouting() {
        scope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                try {
                    val text = String(bytes, Charsets.UTF_8)
                    if (text.startsWith("{")) {
                        val envelope = JSONObject(text)
                        val channelStr = envelope.optString("channel")
                        val payloadStr = envelope.optString("payload")
                        val fromDeviceId = envelope.optString("device_id", "mac_host")
                        val typeStr = envelope.optString("type")
                        val correlationId = envelope.optString("correlation_id")
                        
                        // Handle dashboard channel (battery/telemetry updates) directly
                        if (channelStr.equals("dashboard", ignoreCase = true)) {
                            try {
                                val json = JSONObject(payloadStr)
                                if (json.has("batteryPercent")) {
                                    val pct = json.optDouble("batteryPercent").toInt()
                                    val isChg = json.optBoolean("isCharging", false)
                                    val isOnAC = json.optBoolean("isOnACPower", false)
                                    updateMacBattery(pct, isChg, isOnAC)
                                }
                            } catch (e: Exception) {}
                        }
                        
                        if (typeStr == "response" && correlationId.isNotEmpty()) {
                            if (channelStr.equals("heartbeat", ignoreCase = true)) {
                                val sendTime = webSocketClient.pendingPingTimes.remove(correlationId)
                                if (sendTime != null) {
                                    val rtt = System.currentTimeMillis() - sendTime
                                    updateQoSMetrics(rtt = rtt)
                                }
                            }
                            scope.launch {
                                notifySubscribers { it.onResponseReceived(correlationId, payloadStr, fromDeviceId) }
                            }
                        } else {
                            val channel = MessageChannel.fromString(channelStr)
                            if (channel != null) {
                                if (channel == MessageChannel.SESSION) {
                                    try {
                                        val sessionPayload = JSONObject(payloadStr)
                                        if (sessionPayload.optString("action") == "disconnect") {
                                            LinkOSLogger.info("[ConnectionManager] Intercepted SESSION disconnect request. Tearing down WebSocket client.", "ConnectionState")
                                            this@ConnectionStateManager.disconnect()
                                            return@collect
                                        }
                                    } catch (e: Exception) {}
                                }
                                
                                var finalPayloadStr = payloadStr
                                if (correlationId.isNotEmpty()) {
                                    try {
                                        if (payloadStr.startsWith("{")) {
                                            val payloadObj = JSONObject(payloadStr)
                                            payloadObj.put("correlationId", correlationId)
                                            payloadObj.put("correlation_id", correlationId)
                                            finalPayloadStr = payloadObj.toString()
                                        }
                                    } catch (e: Exception) {}
                                }
                                routeMessage(channel, finalPayloadStr.toByteArray(Charsets.UTF_8), fromDeviceId)
                            }
                        }
                    }
                } catch (e: Exception) {
                    LinkOSLogger.error("Failed to parse incoming envelope in ConnectionStateManager: ${e.message}", "ConnectionState")
                }
            }
        }
    }

    // MARK: - QoS

    fun updateQoSMetrics(rtt: Long? = null, packetLoss: Double? = null, cpuUsage: Double? = null, batteryLow: Boolean? = null) {
        val current = _qos.value
        _qos.value = current.copy(
            packetLossRate = packetLoss ?: current.packetLossRate,
            cpuUsage = cpuUsage ?: current.cpuUsage,
            isBatteryLow = batteryLow ?: current.isBatteryLow
        )
        if (rtt != null) _rttMs.value = rtt
    }

    private fun startQoSEvaluation() {
        qosJob?.cancel()
        qosJob = scope.launch {
            while (isActive) {
                delay(5000L)
                val previous = _qos.value.profile
                val evaluated = _qos.value.evaluate()
                _qos.value = evaluated

                if (evaluated.profile != previous) {
                    LinkOSLogger.info("[QoS] Profile changed: ${previous.name} → ${evaluated.profile.name}", "Performance")
                    notifySubscribers { it.onQoSChanged(evaluated) }
                }
            }
        }
    }

    // MARK: - Helpers

    private suspend fun notifySubscribers(action: suspend (ConnectionStateSubscriber) -> Unit) {
        for ((_, subscriber) in subscribers.toMap()) {
            try {
                action(subscriber)
            } catch (e: Exception) {
                LinkOSLogger.error("Subscriber error: ${e.message}", "ConnectionState")
            }
        }
    }

    private fun isAppInForeground(): Boolean {
        val activityManager = context.getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        val appProcesses = activityManager.runningAppProcesses ?: return false
        val packageName = context.packageName
        for (appProcess in appProcesses) {
            if (appProcess.importance == android.app.ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND && appProcess.processName == packageName) {
                return true
            }
        }
        return false
    }
}
