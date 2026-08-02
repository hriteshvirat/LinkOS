package com.linkos.core.network

import com.linkos.core.device.DeviceInfoProvider
import com.linkos.core.logging.LinkOSLogger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * ConnectionWatchdog monitors the health of the WebSocket and Bonjour stacks on Android.
 *
 * Design principles (matching the macOS watchdog):
 * 1. Each component (WebSocket, Bonjour) is watched independently — a Bonjour hiccup does
 *    not trigger a WebSocket restart and vice versa.
 * 2. Per-component exponential backoff cooldown: restart delays double on consecutive failures
 *    (1s → 2s → 4s … up to MAX_COOLDOWN_MS) and reset to MIN on a successful health check.
 * 3. Manual disconnect is respected — if [WebSocketClient.isManualDisconnect] is true the
 *    watchdog skips WebSocket health checks entirely so it never fights the user.
 * 4. The watchdog only starts if [start] is called explicitly (e.g. from LinkOSService.onCreate).
 *    Calling [stop] cleanly cancels all monitoring jobs.
 */
@Singleton
class ConnectionWatchdog @Inject constructor(
    private val webSocketClient: WebSocketClient,
    private val bonjourClient: BonjourClient,
    private val connectionStateManager: ConnectionStateManager,
    private val deviceInfoProvider: DeviceInfoProvider,
) {
    companion object {
        private const val TAG = "ConnectionWatchdog"
        private const val POLL_INTERVAL_MS = 15_000L     // check every 15 s
        private const val MIN_COOLDOWN_MS  = 1_000L
        private const val MAX_COOLDOWN_MS  = 64_000L     // cap at ~64 s
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private var watchdogJob: Job? = null

    // Per-component cooldown state
    private var wsCooldownMs    = MIN_COOLDOWN_MS
    private var bonjourCooldownMs = MIN_COOLDOWN_MS

    /** Start the watchdog. Safe to call multiple times — subsequent calls are no-ops. */
    fun start() {
        if (watchdogJob?.isActive == true) return
        LinkOSLogger.info("ConnectionWatchdog started (poll=${POLL_INTERVAL_MS}ms)", TAG)
        watchdogJob = scope.launch {
            while (isActive) {
                delay(POLL_INTERVAL_MS)
                checkWebSocket()
                checkBonjour()
            }
        }
    }

    /** Stop the watchdog and cancel all monitoring. */
    fun stop() {
        watchdogJob?.cancel()
        watchdogJob = null
        LinkOSLogger.info("ConnectionWatchdog stopped", TAG)
    }

    // -------------------------------------------------------------------------
    // WebSocket health
    // -------------------------------------------------------------------------

    private suspend fun checkWebSocket() {
        // Respect manual disconnect — never fight the user.
        if (webSocketClient.isManualDisconnect) {
            wsCooldownMs = MIN_COOLDOWN_MS // reset so next auto-reconnect is fast
            return
        }

        val phase = connectionStateManager.phase.value
        if (phase == ConnectionPhase.CONNECTED) {
            // Healthy — reset cooldown.
            wsCooldownMs = MIN_COOLDOWN_MS
            return
        }

        // Not connected and not a manual disconnect — attempt recovery.
        LinkOSLogger.warning(
            "[$TAG] WebSocket unhealthy (phase=$phase). Cooldown=${wsCooldownMs}ms. Attempting recovery.",
            TAG
        )
        delay(wsCooldownMs)
        wsCooldownMs = minOf(wsCooldownMs * 2, MAX_COOLDOWN_MS)

        // Trigger reconnect via ConnectionStateManager (which will call BonjourClient.startDiscovery
        // and then auto-connect on discovery if paired).
        if (phase == ConnectionPhase.DISCONNECTED) {
            connectionStateManager.transition(ConnectionPhase.DISCONNECTED)
        }
    }

    // -------------------------------------------------------------------------
    // Bonjour (NSD) health
    // -------------------------------------------------------------------------

    private suspend fun checkBonjour() {
        // Respect manual disconnect — never fight the user.
        if (webSocketClient.isManualDisconnect) {
            bonjourCooldownMs = MIN_COOLDOWN_MS
            return
        }

        val phase = connectionStateManager.phase.value
        // When connected, discovery is intentionally stopped — nothing to check.
        if (phase == ConnectionPhase.CONNECTED) {
            bonjourCooldownMs = MIN_COOLDOWN_MS
            return
        }

        if (bonjourClient.isDiscovering.value) {
            // Discovery is running — healthy.
            bonjourCooldownMs = MIN_COOLDOWN_MS
            return
        }

        // NSD has stalled while we're not connected — restart discovery.
        LinkOSLogger.warning(
            "[$TAG] Bonjour discovery stalled (phase=$phase). Cooldown=${bonjourCooldownMs}ms. Restarting.",
            TAG
        )
        delay(bonjourCooldownMs)
        bonjourCooldownMs = minOf(bonjourCooldownMs * 2, MAX_COOLDOWN_MS)

        val info = deviceInfoProvider.getDeviceInfo()
        bonjourClient.stopDiscovery()
        bonjourClient.startDiscovery()
        // Re-advertise in case that was also dropped.
        bonjourClient.startAdvertising(info.deviceName, info.deviceId)
    }
}
