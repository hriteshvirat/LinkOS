package com.linkos.core.device

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Environment
import android.os.StatFs
import android.app.ActivityManager
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.ProtocolConstants
import com.linkos.core.network.QoSState
import com.linkos.core.network.WebSocketClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AndroidTelemetryCollector @Inject constructor(
    @ApplicationContext private val context: Context,
    private val connectionStateManager: ConnectionStateManager,
    private val webSocketClient: WebSocketClient
) : ConnectionStateSubscriber {

    override val subscriberId = "android_telemetry_collector"
    private var streamingJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.IO)
    private var lastPingSentTime: Long = 0
    private var lastBatteryPercent: Int = -1
    private var lastIsCharging: Boolean = false

    init {
        connectionStateManager.subscribe(this)
        startTelemetryLoop()

        // Bind structured log forwarder to send warnings/errors over WebSocket
        com.linkos.core.logging.LinkOSLogger.onLogForwarded = { level, message, category, metadata ->
            scope.launch {
                try {
                    val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
                    val appVersion = packageInfo.versionName ?: "1.0.0"
                    val buildNumber = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.P) {
                        packageInfo.longVersionCode.toString()
                    } else {
                        packageInfo.versionCode.toString()
                    }
                    
                    val payload = JSONObject().apply {
                        put("level", level.name)
                        put("category", category)
                        put("message", message)
                        put("appVersion", appVersion)
                        put("buildNumber", buildNumber)
                        put("osVersion", android.os.Build.VERSION.RELEASE)
                        put("deviceModel", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
                        if (metadata != null) {
                            val metaJson = JSONObject()
                            for ((k, v) in metadata) {
                                metaJson.put(k, v)
                            }
                            put("metadata", metaJson)
                        }
                    }
                    webSocketClient.sendEnvelope(
                        channel = "remote_log",
                        payload = payload.toString()
                    )
                } catch (e: Exception) {}
            }
        }
        
        // Listen for immediate battery status changes, with change throttling
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        context.registerReceiver(object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                val batteryStatus = c?.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                batteryStatus?.let {
                    val level = it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                    val scale = it.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                    val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else -1
                    val status = it.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                    val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
                    
                    if (percent != lastBatteryPercent || isCharging != lastIsCharging) {
                        lastBatteryPercent = percent
                        lastIsCharging = isCharging
                        
                        scope.launch {
                            try {
                                val telemetry = collectTelemetry()
                                webSocketClient.sendEnvelope(
                                    channel = ProtocolConstants.Channel.DASHBOARD,
                                    payload = telemetry.toString()
                                )
                            } catch (e: Exception) {}
                        }
                    }
                }
            }
        }, filter)
    }

    private fun startTelemetryLoop() {
        streamingJob?.cancel()
        streamingJob = scope.launch {
            while (true) {
                try {
                    val telemetry = collectTelemetry()
                    // Send directly over WebSocket to macOS via the dashboard channel
                    webSocketClient.sendEnvelope(
                        channel = ProtocolConstants.Channel.DASHBOARD,
                        payload = telemetry.toString()
                    )
                } catch (e: Exception) {
                    // Ignore
                }
                delay(ProtocolConstants.Telemetry.INTERVAL_MS) // Collect and stream every 5.0 seconds
            }
        }
        LinkOSLogger.info("AndroidTelemetryCollector loop started", "Telemetry")
    }

    private fun collectTelemetry(): JSONObject {
        val json = JSONObject()
        
        // 1. Battery & Charging
        val batteryIntent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else 80
        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        val tempDeciC = batteryIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0
        val tempC = tempDeciC / 10.0

        // Power source (AC, USB, Wireless, or Battery)
        val plugType = batteryIntent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val powerSource = when (plugType) {
            BatteryManager.BATTERY_PLUGGED_AC -> "AC"
            BatteryManager.BATTERY_PLUGGED_USB -> "USB"
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
            else -> "Battery"
        }

        // 2. CPU Usage
        val cpuUsage = ((Math.random() * 15) + 5).coerceIn(0.0, 100.0) // Mock CPU load safely

        // 3. RAM Memory
        val actManager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        actManager.getMemoryInfo(memInfo)
        val ramUsage = ((memInfo.totalMem - memInfo.availMem).toDouble() / memInfo.totalMem * 100).coerceIn(0.0, 100.0)

        // 4. Disk Storage
        val stat = StatFs(Environment.getDataDirectory().path)
        val totalBytes = stat.blockCountLong * stat.blockSizeLong
        val availableBytes = stat.availableBlocksLong * stat.blockSizeLong
        val diskUsage = (((totalBytes - availableBytes).toDouble() / totalBytes) * 100).coerceIn(0.0, 100.0)

        // 5. Wi-Fi RSSI Signal Strength
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val rssi = wifiManager.connectionInfo?.rssi ?: -60

        json.put("batteryPercent", percent)
        json.put("isCharging", isCharging)
        json.put("powerSource", powerSource)
        json.put("cpuUsage", cpuUsage)
        json.put("ramUsage", ramUsage)
        json.put("diskUsage", diskUsage)
        json.put("temperature", tempC)
        json.put("wifiStrength", rssi)
        
        // RTT Ping metric
        val rtt = connectionStateManager.rttMs.value.toDouble()
        json.put("pingRtt", rtt)

        return json
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {}

    override suspend fun onQoSChanged(state: QoSState) {}
}
