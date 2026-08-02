package com.linkos.core.network

import com.linkos.core.device.DeviceInfoProvider
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.security.EncryptedSession
import com.linkos.core.security.E2EEncryption
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import okhttp3.*
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton
import android.content.Context
import android.content.Intent
import dagger.hilt.android.qualifiers.ApplicationContext

/**
 * Simplified connection state machine visible to the UI.
 */
enum class ConnectionState {
    DISCONNECTED,
    CONNECTING,
    PAIRING,
    CONNECTED,
}

/**
 * WebSocket client for the control channel.
 * Connects to the macOS host's WebSocket server for bidirectional messaging.
 */
@Singleton
class PairingSession(val id: String)

@Singleton
class WebSocketClient @Inject constructor(
    private val deviceInfoProvider: DeviceInfoProvider,
    private val keystoreManager: com.linkos.core.security.KeystoreManager,
    @ApplicationContext private val context: Context
) {

    private val client = OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)  // No timeout for WebSocket
        .pingInterval(30, TimeUnit.SECONDS)
        .build()

    private var webSocket: WebSocket? = null
    private var encryptedSession: EncryptedSession? = null
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val msgIdCounter = java.util.concurrent.atomic.AtomicLong(0)

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    var isManualDisconnect = false
    private var lastReceivedTimeMs = 0L

    init {
        scope.launch {
            _state.collect { state ->
                if (state == ConnectionState.CONNECTED) {
                    lastReceivedTimeMs = System.currentTimeMillis()
                    startHeartbeatLoop()
                    val host = lastHost
                    val port = lastPort
                    if (host != null && port != null) {
                        connectInputWebSocket(host, port)
                    }
                } else {
                    heartbeatJob?.cancel()
                    try {
                        inputWebSocket?.close(1000, "State changed from connected")
                    } catch (e: Exception) {
                        inputWebSocket?.cancel()
                    }
                    inputWebSocket = null
                }
            }
        }
    }

    private fun connectInputWebSocket(host: String, port: Int) {
        val url = "ws://$host:$port/input?deviceId=${deviceInfoProvider.getDeviceInfo().deviceId}"
        val request = Request.Builder()
            .url(url)
            .header("X-LinkOS-Input", "1")
            .build()
        inputWebSocket = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                com.linkos.core.logging.LinkOSLogger.info("[InputWebSocket] Connected successfully to input channel", "Network")
            }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                com.linkos.core.logging.LinkOSLogger.error("[InputWebSocket] Connection failed: ${t.message}", "Network")
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                com.linkos.core.logging.LinkOSLogger.info("[InputWebSocket] Connection closed: $reason", "Network")
            }
        })
    }

    // Active Pairing Session
    var activeSession: PairingSession? = null

    // Connected Mac name
    val connectedMacName = MutableStateFlow("Mac Host")

    // Show pairing PIN code to Android user (for Mac-initiated flow)
    val showPinCodeToUser = MutableStateFlow<String?>(null)

    // Request PIN code entry from Android user (for Android-initiated flow)
    val requestPinCodeFromUser = MutableStateFlow<Boolean>(false)

    // Flag to indicate connection failure with troubleshooting info
    val hasConnectionFailed = MutableStateFlow(false)
    val lastFailureStage = MutableStateFlow<String?>(null)
    val pendingPingTimes = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private var inputWebSocket: WebSocket? = null

    private val _messageFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 128)
    val messageFlow: SharedFlow<ByteArray> = _messageFlow.asSharedFlow()

    var onConnected: (suspend () -> Unit)? = null
    var onDisconnected: (suspend () -> Unit)? = null

    // Last connection properties
    private var lastConnectedHost: String? = null
    private var lastConnectedPort: Int = 52637

    // Pairing Code
    private var activePairingCode: String? = null
    private var pendingPairingInitiator: String? = null // "android" or "mac"
    private var pendingPairingMethod: String? = null // "PIN", "QR", "DIRECT", "TRUSTED"

    // Watchdog & Reconnection State Machine
    private var reconnectAttempts = 0
    private val maxReconnectAttempts = 5
    private var lastHost: String? = null
    private var lastPort: Int? = null
    private var reconnectJob: Job? = null
    private var watchdogJob: Job? = null

    fun destroySession(reason: String) {
        val sessionId = activeSession?.id ?: "NONE"
        LinkOSLogger.info("[SESSION #$sessionId] DESTROYED. Reason: $reason", "Network")
        
        watchdogJob?.cancel()
        watchdogJob = null
        reconnectJob?.cancel()
        reconnectJob = null
        
        try {
            webSocket?.close(1000, "Session Destroyed")
        } catch (e: Exception) {
            webSocket?.cancel()
        }
        webSocket = null
        
        try {
            inputWebSocket?.close(1000, "Session Destroyed")
        } catch (e: Exception) {
            inputWebSocket?.cancel()
        }
        inputWebSocket = null
        
        encryptedSession = null
        activePairingCode = null
        pendingPairingInitiator = null
        pendingPairingMethod = null
        reconnectAttempts = 0
        
        showPinCodeToUser.value = null
        requestPinCodeFromUser.value = false
        _state.value = ConnectionState.DISCONNECTED
        activeSession = null
    }

    private fun startWatchdog(timeoutMs: Long, stage: Int, reason: String) {
        watchdogJob?.cancel()
        val session = activeSession ?: return
        val sessionId = session.id
        watchdogJob = scope.launch {
            delay(timeoutMs)
            if (activeSession?.id == sessionId && _state.value != ConnectionState.CONNECTED) {
                LinkOSLogger.warning("[SESSION #$sessionId] Watchdog fired: Stage $stage failure - $reason", "Network")
                lastFailureStage.value = "Stage $stage Failure: $reason"
                destroySession("Watchdog timeout")
            }
        }
    }

    fun setPendingPairingInitiator(initiator: String) {
        // Destroy existing session first to start from a clean state
        destroySession("New incoming invitation invite")
        
        val sessionId = String.format("%04X", (0..0xFFFF).random())
        val session = PairingSession(sessionId)
        activeSession = session
        
        LinkOSLogger.info("[SESSION #$sessionId] CREATED (via incoming invitation)", "Network")
        
        pendingPairingInitiator = initiator
        if (initiator == "mac") {
            _state.value = ConnectionState.PAIRING
        }
    }

    /**
     * Connect to a macOS host WebSocket server.
     */
    fun connect(host: String, port: Int, pairingCode: String? = null, method: String? = null) {
        val serviceIntent = Intent(context, com.linkos.core.service.LinkOSService::class.java)
        try {
            androidx.core.content.ContextCompat.startForegroundService(context, serviceIntent)
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to start LinkOSService on connect: ${e.message}", "Network")
        }
        isManualDisconnect = false
        requestPinCodeFromUser.value = false
        destroySession("Starting new pairing attempt")
        
        val sessionId = String.format("%04X", (0..0xFFFF).random())
        val session = PairingSession(sessionId)
        activeSession = session
        
        LinkOSLogger.info("[SESSION #$sessionId] CREATED", "Network")
        
        lastHost = host
        lastPort = port
        activePairingCode = pairingCode
        pendingPairingMethod = method ?: if (pairingCode != null) "PIN" else "DIRECT"
        pendingPairingInitiator = if (method == "PIN" || pairingCode != null) "android" else null
        _state.value = ConnectionState.CONNECTING
        hasConnectionFailed.value = false
        lastFailureStage.value = null

        startWatchdog(15_000, 2, "WebSocket connection timed out before socket established.")

        val url = "ws://$host:$port"
        val request = Request.Builder()
            .url(url)
            .header("X-LinkOS-Protocol", "1")
            .build()

        webSocket = client.newWebSocket(request, createListener())
        LinkOSLogger.info("[SESSION #$sessionId] Connecting to $url with code $pairingCode (method: $pendingPairingMethod)", "Network")
    }

    fun retry() {
        val host = lastHost
        val port = lastPort
        if (host != null && port != null) {
            connect(host, port, activePairingCode, pendingPairingMethod)
        }
    }

    /**
     * Send pairing request with user-entered PIN code.
     */
    fun sendPairingRequest(code: String) {
        startWatchdog(20_000, 8, "Pairing request timed out waiting for Mac approval.")

        val json = JSONObject().apply {
            put("type", "PAIRING_REQUEST")
            put("deviceId", deviceInfoProvider.getDeviceInfo().deviceId)
            put("deviceName", deviceInfoProvider.getDeviceInfo().deviceName)
            put("pairingCode", code)
        }
        webSocket?.send(json.toString())
        requestPinCodeFromUser.value = false
    }

    fun disconnect() {
        isManualDisconnect = true
        try {
            sendEnvelope("session", """{"action":"disconnect","manual":true}""")
        } catch (_: Exception) {}
        
        // NOTE: Do NOT clear pairing keys on manual disconnect.
        // Pairing keys are preserved so the user can reconnect
        // from the discovered devices list without re-pairing.
        
        heartbeatJob?.cancel()
        watchdogJob?.cancel()
        reconnectJob?.cancel()
        
        try {
            inputWebSocket?.close(1000, "User disconnected")
        } catch (_: Exception) {}
        inputWebSocket = null
        
        webSocket?.close(1000, "User disconnected")
        webSocket = null
        encryptedSession = null
        _state.value = ConnectionState.DISCONNECTED
        destroySession("User initiated disconnect")
        LinkOSLogger.info("Disconnected cleanly", "Network")
    }

    /**
     * Send raw bytes (encrypted if session established).
     */
    fun send(data: ByteArray) {
        val payload = encryptedSession?.encrypt(data) ?: data
        webSocket?.send(payload.toByteString())
    }

    /**
     * Send structured envelope.
     *
     * For "request" type messages, a correlationId is automatically generated if not provided.
     * The correlationId is returned (not the internal message-UUID) so callers can store it
     * in pending-ACK maps and correlate against macOS responses.
     */
    fun sendEnvelope(channel: String, payload: String, type: String = "event", correlationId: String? = null): String {
        if (channel == "trackpad" && inputWebSocket != null) {
            inputWebSocket?.send(payload)
            return correlationId ?: "msg_${System.currentTimeMillis()}_${msgIdCounter.incrementAndGet()}"
        }
        
        val uniqueId = "msg_${System.currentTimeMillis()}_${msgIdCounter.incrementAndGet()}"
        // For request messages, ensure there is always a correlationId so macOS ACKs can be matched.
        val resolvedCorrelationId: String? = when {
            correlationId != null -> correlationId
            type == "request" -> java.util.UUID.randomUUID().toString()
            else -> null
        }
        val envelope = JSONObject().apply {
            put("message_id", uniqueId)
            put("type", type)
            put("channel", channel)
            put("timestamp", System.currentTimeMillis())
            put("payload", payload)
            if (resolvedCorrelationId != null) {
                put("correlation_id", resolvedCorrelationId)
            }
            put("protocol_version", ProtocolConstants.PROTOCOL_VERSION)
            put("device_id", deviceInfoProvider.getDeviceInfo().deviceId)
        }
        send(envelope.toString().toByteArray(Charsets.UTF_8))
        // Return the correlationId for request messages so callers can await ACKs correctly.
        // For non-request messages, return the message-UUID as before.
        return resolvedCorrelationId ?: uniqueId
    }

    /**
     * Set the encrypted session after pairing.
     */
    fun setEncryptedSession(session: EncryptedSession) {
        this.encryptedSession = session
    }

    private fun createListener() = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            _state.value = ConnectionState.PAIRING
            
            val isPaired = keystoreManager.getString("is_paired") == "true"
            if (pendingPairingMethod == "PIN" && activePairingCode == null && !isPaired) {
                val initJson = JSONObject().apply {
                    put("type", "PAIRING_INIT")
                    put("initiator", "android")
                    put("method", "PIN")
                }
                webSocket.send(initJson.toString())
                requestPinCodeFromUser.value = true
                startWatchdog(15_000, 4, "Timed out waiting for PIN generation on Mac.")
            } else {
                val deviceInfo = deviceInfoProvider.getDeviceInfo()
                val json = JSONObject().apply {
                    put("type", "PAIRING_REQUEST")
                    put("deviceId", deviceInfo.deviceId)
                    put("deviceName", deviceInfo.deviceName)
                    put("model", deviceInfo.model)
                    put("manufacturer", deviceInfo.manufacturer)
                    put("osVersion", deviceInfo.osVersion)
                    if (activePairingCode != null) {
                        put("pairingCode", activePairingCode)
                    }
                }
                webSocket.send(json.toString())
                startWatchdog(20_000, 8, "Pairing request timed out waiting for Mac user approval.")
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            lastReceivedTimeMs = System.currentTimeMillis()
            val sessionId = activeSession?.id ?: "NONE"
            val rawData = bytes.toByteArray()
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] ENTER onMessage(bytes) len=${rawData.size}", "Network")
            
            if (encryptedSession == null) {
                val text = String(rawData, Charsets.UTF_8)
                LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] Binary frame received during unencrypted stage. Routing to text handler. Raw: $text", "Network")
                handleTextMessage(webSocket, text)
            } else {
                val plaintext = try {
                    encryptedSession?.decrypt(rawData) ?: rawData
                } catch (e: Exception) {
                    LinkOSLogger.error("[SESSION #$sessionId] Decryption failed: ${e.message}", "Security")
                    return
                }
                scope.launch { _messageFlow.emit(plaintext) }
            }
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] EXIT onMessage(bytes)", "Network")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            lastReceivedTimeMs = System.currentTimeMillis()
            val sessionId = activeSession?.id ?: "NONE"
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] ENTER onMessage(text) len=${text.length}", "Network")
            handleTextMessage(webSocket, text)
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] EXIT onMessage(text)", "Network")
        }

        private fun handleTextMessage(webSocket: WebSocket, text: String) {
            val sessionId = activeSession?.id ?: "NONE"
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] FRAME RECEIVED opcode=text length=${text.length}", "Network")
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] RAW UTF-8 STRING: $text", "Network")
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] UTF8 SUCCESS", "Network")
            LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] JSON PARSE START", "Network")
            
            try {
                val json = JSONObject(text)
                val type = json.optString("type")
                LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] JSON PARSE SUCCESS type=$type", "Network")
                LinkOSLogger.info("[SESSION #$sessionId] [TRANSPORT] DISPATCHING TO HANDLEINCOMINGDATA type=$type", "Network")
                
                when (type) {
                    "PAIRING_PIN_DISPLAYED" -> {
                        MainScope().launch {
                            requestPinCodeFromUser.value = true
                        }
                        LinkOSLogger.info("[SESSION #$sessionId] [STAGE 5] PIN dialog shown (Mac host displayed PIN on screen)", "Network")
                        startWatchdog(30_000, 6, "Timed out waiting for user to input PIN code.")
                    }
                    "PAIRING_QR_DISPLAYED" -> {
                        LinkOSLogger.info("[SESSION #$sessionId] Mac is displaying QR code.", "Network")
                    }
                    "PAIRING_REQUEST" -> {
                        val code = json.optString("pairingCode")
                        if (code == activePairingCode) {
                            MainScope().launch {
                                showPinCodeToUser.value = null
                                requestPinCodeFromUser.value = false
                                hasConnectionFailed.value = false
                                _state.value = ConnectionState.CONNECTED
                            }
                            val approvedJson = JSONObject().apply {
                                put("type", "PAIRING_APPROVED")
                                put("macName", deviceInfoProvider.getDeviceInfo().deviceName)
                            }
                            webSocket.send(approvedJson.toString())
                            scope.launch { onConnected?.invoke() }
                        } else {
                            val rejectedJson = JSONObject().apply {
                                put("type", "PAIRING_REJECTED")
                                put("reason", "Incorrect PIN Code")
                            }
                            webSocket.send(rejectedJson.toString())
                            MainScope().launch {
                                showPinCodeToUser.value = null
                                requestPinCodeFromUser.value = false
                                _state.value = ConnectionState.DISCONNECTED
                            }
                        }
                    }
                    "PAIRING_APPROVED" -> {
                        try {
                            val macName = json.optString("macName", "Mac Host")
                            startWatchdog(10_000, 10, "Cryptographic key exchange timed out.")
                            
                            val macPubKeyBase64 = json.optString("publicKey", "")
                            if (!macPubKeyBase64.isNullOrEmpty()) {
                                val macPubKeyBytes = android.util.Base64.decode(macPubKeyBase64, android.util.Base64.NO_WRAP)
                                val macPubKey = E2EEncryption.deserializePublicKey(macPubKeyBytes)
                                val ownKeyPair = E2EEncryption.generateKeyPair()
                                val ownPrivateKey = ownKeyPair.private as java.security.interfaces.ECPrivateKey
                                val ownPublicKey = ownKeyPair.public as java.security.interfaces.ECPublicKey
                                val sessionKey = E2EEncryption.deriveSessionKey(ownPrivateKey, macPubKey)
                                val session = EncryptedSession(deviceInfoProvider.getDeviceInfo().deviceId, sessionKey)
                                setEncryptedSession(session)
                                
                                val ownPubKeyBytes = E2EEncryption.serializePublicKey(ownPublicKey)
                                val ownPubKeyBase64 = android.util.Base64.encodeToString(ownPubKeyBytes, android.util.Base64.NO_WRAP)
                                val keyExchange = JSONObject().apply {
                                    put("type", "KEY_EXCHANGE")
                                    put("publicKey", ownPubKeyBase64)
                                }
                                webSocket.send(keyExchange.toString())
                            }
                            
                            watchdogJob?.cancel()
                            watchdogJob = null
                            
                            MainScope().launch {
                                reconnectAttempts = 0
                                hasConnectionFailed.value = false
                                showPinCodeToUser.value = null
                                requestPinCodeFromUser.value = false
                                connectedMacName.value = macName
                                _state.value = ConnectionState.CONNECTED
                                lastHost?.let { host ->
                                    keystoreManager.storeString("is_paired", "true")
                                    keystoreManager.storeString("last_mac_host", host)
                                    keystoreManager.storeString("last_mac_port", lastPort.toString())
                                }
                                LinkOSLogger.info("[Connection] Connected to $macName", "Connection")
                            }
                            scope.launch { onConnected?.invoke() }
                            activeSession = null
                        } catch (e: Exception) {
                            MainScope().launch {
                                connectedMacName.value = json.optString("macName", "Mac Host")
                                _state.value = ConnectionState.CONNECTED
                                LinkOSLogger.info("[Connection] Connected to Mac Host", "Connection")
                            }
                        }
                    }
                    "PAIRING_REJECTED" -> {
                        MainScope().launch {
                            keystoreManager.remove("is_paired")
                            keystoreManager.remove("last_mac_host")
                            keystoreManager.remove("last_mac_port")
                            hasConnectionFailed.value = true
                            _state.value = ConnectionState.DISCONNECTED
                            destroySession("Pairing request rejected by Mac host.")
                        }
                    }
                    else -> {
                        scope.launch { _messageFlow.emit(text.toByteArray()) }
                    }
                }
            } catch (e: Exception) {
                scope.launch { _messageFlow.emit(text.toByteArray()) }
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            val sessionId = activeSession?.id ?: "NONE"
            LinkOSLogger.info("[SESSION #$sessionId] WebSocket connection closed by peer. Code: $code, Reason: $reason", "Network")
            destroySession("Closed by peer: $reason")
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            val sessionId = activeSession?.id ?: "NONE"
            LinkOSLogger.error("[SESSION #$sessionId] WebSocket transport error: ${t.message}", "Network")
            
            val wasConnected = (_state.value == ConnectionState.CONNECTED)
            if (!wasConnected) {
                hasConnectionFailed.value = true
                if (lastFailureStage.value == null) {
                    lastFailureStage.value = "Stage 2 Failure: WebSocket handshake failed or cleartext traffic blocked."
                }
            }
            destroySession("Transport failure: ${t.message}")
        }
    }

    private var heartbeatJob: Job? = null

    fun startHeartbeatLoop() {
        heartbeatJob?.cancel()
        heartbeatJob = scope.launch {
            while (isActive && _state.value == ConnectionState.CONNECTED) {
                // Heartbeat check: missed twice (8s of silence) = disconnect
                if (System.currentTimeMillis() - lastReceivedTimeMs > 8000L) {
                    LinkOSLogger.warning("Heartbeat missed twice (8s silence). Reconnecting.", "Network")
                    destroySession("Heartbeat timeout")
                    attemptReconnectSilent()
                    break
                }
                
                // Send ping envelope every 4 seconds (ProtocolConstants.Heartbeat.INTERVAL_MS / INTERVAL_SECONDS)
                try {
                    val msgId = sendEnvelope(ProtocolConstants.Channel.HEARTBEAT, """{"type":"ping"}""")
                    pendingPingTimes[msgId] = System.currentTimeMillis()
                } catch (_: Exception) {
                    break
                }
                delay(4000L)
            }
        }
    }

    private fun attemptReconnectSilent() {
        val host = lastHost
        val port = lastPort

        if (host == null || port == null || reconnectAttempts >= maxReconnectAttempts || isManualDisconnect) {
            LinkOSLogger.info("Silent reconnection limit reached or manual disconnect ($reconnectAttempts/$maxReconnectAttempts).", "Network")
            reconnectAttempts = 0
            _state.value = ConnectionState.DISCONNECTED
            hasConnectionFailed.value = true
            scope.launch { onDisconnected?.invoke() }
            return
        }

        reconnectAttempts++
        
        // Reconnect silently in the background without setting state to CONNECTING
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            val backoffDelay = 1000L * (1L shl minOf(reconnectAttempts - 1, 4)) // 1s, 2s, 4s, 8s, 16s
            delay(backoffDelay)
            LinkOSLogger.info("Executing silent reconnection attempt $reconnectAttempts/$maxReconnectAttempts to $host:$port", "Network")
            
            val url = "ws://$host:$port"
            val request = Request.Builder()
                .url(url)
                .header("X-LinkOS-Protocol", "1")
                .build()

            webSocket = client.newWebSocket(request, createListener())
        }
    }
}
