package com.linkos.core.service

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.IBinder
import android.os.Environment
import android.widget.Toast
import android.widget.RemoteViews
import android.graphics.Bitmap
import java.io.File
import androidx.core.app.NotificationCompat
import com.linkos.core.device.DeviceInfoProvider
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.BonjourClient
import com.linkos.core.network.ConnectionPhase
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.ConnectionWatchdog
import com.linkos.core.network.InviteListener
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.WebSocketClient
import com.linkos.R
import com.linkos.features.clipboard.ClipboardHistoryItem
import com.linkos.features.clipboard.ClipboardHistoryManager
import com.linkos.features.clipboard.ClipboardType
import com.linkos.features.clipboard.ClipboardSyncActivity
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.UUID
import javax.inject.Inject

@AndroidEntryPoint
class LinkOSService : Service(), ConnectionStateSubscriber {

    @Inject
    lateinit var connectionStateManager: ConnectionStateManager

    @Inject
    lateinit var webSocketClient: WebSocketClient

    @Inject
    lateinit var inviteListener: InviteListener

    @Inject
    lateinit var bonjourClient: BonjourClient

    @Inject
    lateinit var deviceInfoProvider: DeviceInfoProvider

    @Inject
    lateinit var clipboardHistoryManager: ClipboardHistoryManager

    @Inject
    lateinit var connectionWatchdog: ConnectionWatchdog

    private val serviceScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private lateinit var clipboardManager: ClipboardManager

    private var lastSyncedText: String? = null
    private var lastSyncTimestamp: Long = 0
    private var lastSyncOrigin: String = "local"
    private var clipboardReceiver: BroadcastReceiver? = null
    private var batteryReceiver: BroadcastReceiver? = null
    private val pendingAcks = java.util.concurrent.ConcurrentHashMap<String, kotlinx.coroutines.CompletableDeferred<Boolean>>()

    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        serviceScope.launch {
            if (isAppInForeground()) {
                handleLocalClipboardChange()
            } else {
                try {
                    val helperIntent = Intent(this@LinkOSService, ClipboardSyncActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
                        addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                    }
                    startActivity(helperIntent)
                } catch (e: Exception) {
                    LinkOSLogger.error("Failed to launch background clipboard sync helper activity: ${e.message}", "ClipboardSync")
                }
            }
        }
    }

    override val subscriberId = "linkos_background_service"

    private fun isAppInForeground(): Boolean {
        val activityManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val appProcesses = activityManager.runningAppProcesses ?: return false
        val packageName = packageName
        for (appProcess in appProcesses) {
            if (appProcess.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND && appProcess.processName == packageName) {
                return true
            }
        }
        return false
    }

    private var disconnectTimeoutJob: kotlinx.coroutines.Job? = null

    private fun scheduleDisconnectTimeout() {
        if (disconnectTimeoutJob != null) return
        LinkOSLogger.info("Scheduling 2-minute auto-teardown job.", "Service")
        disconnectTimeoutJob = serviceScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            kotlinx.coroutines.delay(120_000) // 2 minutes
            LinkOSLogger.info("2-minute disconnect timeout reached. Stopping foreground service.", "Service")
            stopSelf()
        }
    }

    private fun cancelDisconnectTimeout() {
        disconnectTimeoutJob?.cancel()
        disconnectTimeoutJob = null
        LinkOSLogger.info("Active connection established. Disconnect timeout cancelled.", "Service")
    }

    override fun onCreate() {
        super.onCreate()
        LinkOSLogger.info("LinkOS Foreground Service onCreate", "Service")
        
        clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboardManager.addPrimaryClipChangedListener(clipListener)
        connectionStateManager.subscribe(this)
        registerAccessibilityObserver()

        val filter = IntentFilter("com.linkos.action.CLIPBOARD_SYNCED")
        clipboardReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val text = intent?.getStringExtra("text") ?: return
                handleClipboardSyncFromHelper(text)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(clipboardReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(clipboardReceiver, filter)
        }

        // Register global battery receiver
        val batteryFilter = IntentFilter().apply {
            addAction(Intent.ACTION_BATTERY_CHANGED)
            addAction(Intent.ACTION_POWER_CONNECTED)
            addAction(Intent.ACTION_POWER_DISCONNECTED)
        }
        batteryReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val batteryStatus = context?.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                batteryStatus?.let {
                    val level = it.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1)
                    val scale = it.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, -1)
                    val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else 80
                    val status = it.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1)
                    val isCharging = status == android.os.BatteryManager.BATTERY_STATUS_CHARGING || status == android.os.BatteryManager.BATTERY_STATUS_FULL
                    val plugType = it.getIntExtra(android.os.BatteryManager.EXTRA_PLUGGED, 0)
                    val powerSource = when (plugType) {
                        android.os.BatteryManager.BATTERY_PLUGGED_AC -> "AC"
                        android.os.BatteryManager.BATTERY_PLUGGED_USB -> "USB"
                        android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Wireless"
                        else -> "Battery"
                    }
                    connectionStateManager.updateAndroidBattery(percent, isCharging, powerSource)
                }
            }
        }
        registerReceiver(batteryReceiver, batteryFilter)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, createNotification(), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, createNotification())
        }

        // Start mDNS advertising and invite listening
        inviteListener.startListening()
        val info = deviceInfoProvider.getDeviceInfo()
        bonjourClient.startAdvertising(info.deviceName, info.deviceId)

        // Schedule initial 2-minute timeout if not connected
        if (connectionStateManager.phase.value != com.linkos.core.network.ConnectionPhase.CONNECTED) {
            scheduleDisconnectTimeout()
        }

        // Start health watchdog — monitors WebSocket + Bonjour and restarts each independently
        connectionWatchdog.start()

        // Observe connection phase and discovery state to update notification or stop service
        serviceScope.launch {
            kotlinx.coroutines.flow.combine(
                bonjourClient.isDiscovering,
                connectionStateManager.phase
            ) { isDiscovering, phase ->
                Pair(isDiscovering, phase)
            }.collect { (isDiscovering, phase) ->
                val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                manager.notify(NOTIFICATION_ID, createNotification())

                if (phase == com.linkos.core.network.ConnectionPhase.DISCONNECTED && !isDiscovering && !isAppInForeground()) {
                    LinkOSLogger.info("Not connected, scanning stopped, and app is in background. Stopping foreground service to remove notification.", "Service")
                    stopSelf()
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent != null && intent.action != null) {
            val action = intent.action
            LinkOSLogger.info("Received notification action: $action", "Service")
            // Trigger haptic feedback immediately on notification action tap
            com.linkos.ui.components.HapticUtils.lightTap(this@LinkOSService)
            serviceScope.launch {
                try {
                    when (action) {
                        ACTION_BRIGHTNESS_DOWN -> {
                            webSocketClient.sendEnvelope("touchpad", "{\"action\":\"media\",\"key\":\"brightness_down\"}", type = "event")
                        }
                        ACTION_BRIGHTNESS_UP -> {
                            webSocketClient.sendEnvelope("touchpad", "{\"action\":\"media\",\"key\":\"brightness_up\"}", type = "event")
                        }
                        ACTION_VOLUME_DOWN -> {
                            webSocketClient.sendEnvelope("touchpad", "{\"action\":\"media\",\"key\":\"vol_down\"}", type = "event")
                        }
                        ACTION_VOLUME_UP -> {
                            webSocketClient.sendEnvelope("touchpad", "{\"action\":\"media\",\"key\":\"vol_up\"}", type = "event")
                        }
                        ACTION_SCREENSHOT -> {
                            webSocketClient.sendEnvelope("streamdeck", "{\"action_type\":\"TAKE_SCREENSHOT\",\"params\":{}}", type = "request")
                        }
                        ACTION_SEND_CLIPBOARD -> {
                            val helperIntent = Intent(this@LinkOSService, ClipboardSyncActivity::class.java).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                            }
                            startActivity(helperIntent)
                        }
                        ACTION_DISCONNECT -> {
                            connectionStateManager.disconnect()
                        }
                    }
                } catch (e: Exception) {
                    LinkOSLogger.error("Failed to execute notification action $action: ${e.message}", "Service")
                }
            }
        }
        return START_STICKY
    }

    override suspend fun onConnectionPhaseChanged(phase: com.linkos.core.network.ConnectionPhase, device: com.linkos.core.network.PeerDevice?) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, createNotification())

        if (phase == com.linkos.core.network.ConnectionPhase.CONNECTED) {
            cancelDisconnectTimeout()
            sendCapabilitiesToMac(isAccessibilityEnabled())
        } else {
            scheduleDisconnectTimeout()
            
            val keys = pendingAcks.keys().toList()
            for (key in keys) {
                pendingAcks.remove(key)?.complete(false)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        LinkOSLogger.info("LinkOS Foreground Service onDestroy", "Service")
        connectionWatchdog.stop()
        clipboardManager.removePrimaryClipChangedListener(clipListener)
        connectionStateManager.unsubscribe(subscriberId)
        unregisterAccessibilityObserver()
        clipboardReceiver?.let {
            unregisterReceiver(it)
            clipboardReceiver = null
        }
        batteryReceiver?.let {
            unregisterReceiver(it)
            batteryReceiver = null
        }
        inviteListener.stopListening()
        bonjourClient.stopAdvertising()
        bonjourClient.stopDiscovery()
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun handleLocalClipboardChange() {
        val clip = clipboardManager.primaryClip ?: return
        if (clip.itemCount == 0) return
        val text = clip.getItemAt(0).text?.toString() ?: return
        if (text.isEmpty()) return

        // Loop prevention
        if (text == lastSyncedText) return

        val now = System.currentTimeMillis()
        if (now - lastSyncTimestamp < 600 && lastSyncOrigin == "remote") {
            return
        }

        lastSyncedText = text
        lastSyncTimestamp = now
        lastSyncOrigin = "local"

        LinkOSLogger.info("Local clipboard changed: ${text.take(30)}", "ClipboardSync")

        // Add to history manager
        val historyItem = ClipboardHistoryItem(
            id = UUID.randomUUID().toString(),
            contentType = if (text.startsWith("http")) ClipboardType.URL else ClipboardType.TEXT,
            previewText = text.take(100),
            fullText = text,
            mimeType = "text/plain",
            sourceApp = "Android Device",
            timestamp = now,
            sizeBytes = text.length
        )
        clipboardHistoryManager.addItem(historyItem)

        // Broadcast raw text to Mac over WebSocket, wait for ACK.
        // sendEnvelope(type="request") now auto-generates a correlationId and returns it —
        // so we store pendingAcks[correlationId]. The macOS side ACKs with that same correlationId.
        val correlationId = webSocketClient.sendEnvelope("clipboard", text, type = "request")
        val deferred = kotlinx.coroutines.CompletableDeferred<Boolean>()
        pendingAcks[correlationId] = deferred
        LinkOSLogger.info("Clipboard sync sent. correlationId=$correlationId, preview=${text.take(20)}", "ClipboardSync")
        
        serviceScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            try {
                kotlinx.coroutines.withTimeout(5000L) {
                    val success = deferred.await()
                    if (success) {
                        Toast.makeText(this@LinkOSService, "✓ Clipboard synced to Mac", Toast.LENGTH_SHORT).show()
                    } else {
                        Toast.makeText(this@LinkOSService, "Mac reported an error. Check connection.", Toast.LENGTH_SHORT).show()
                    }
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                Toast.makeText(this@LinkOSService, "Mac disconnected during sync. Try again.", Toast.LENGTH_SHORT).show()
            } finally {
                pendingAcks.remove(correlationId)
            }
        }
    }

    private fun handleClipboardSyncFromHelper(text: String) {
        if (text.isEmpty()) return
        if (text == lastSyncedText) return

        val now = System.currentTimeMillis()
        if (now - lastSyncTimestamp < 600 && lastSyncOrigin == "remote") {
            return
        }

        lastSyncedText = text
        lastSyncTimestamp = now
        lastSyncOrigin = "local"

        LinkOSLogger.info("Local background clipboard changed: ${text.take(30)}", "ClipboardSync")

        val historyItem = ClipboardHistoryItem(
            id = UUID.randomUUID().toString(),
            contentType = if (text.startsWith("http")) ClipboardType.URL else ClipboardType.TEXT,
            previewText = text.take(100),
            fullText = text,
            mimeType = "text/plain",
            sourceApp = "Android Device (Background)",
            timestamp = now,
            sizeBytes = text.length
        )
        clipboardHistoryManager.addItem(historyItem)
        
        val correlationId = webSocketClient.sendEnvelope("clipboard", text, type = "request")
        val deferred = kotlinx.coroutines.CompletableDeferred<Boolean>()
        pendingAcks[correlationId] = deferred
        LinkOSLogger.info("Background clipboard sync sent. correlationId=$correlationId, preview=${text.take(20)}", "ClipboardSync")
        
        serviceScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            try {
                kotlinx.coroutines.withTimeout(5000L) {
                    val success = deferred.await()
                    if (success) {
                        Toast.makeText(this@LinkOSService, "✓ Clipboard synced to Mac", Toast.LENGTH_SHORT).show()
                    } else {
                        Toast.makeText(this@LinkOSService, "Mac reported an error. Check connection.", Toast.LENGTH_SHORT).show()
                    }
                }
            } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
                Toast.makeText(this@LinkOSService, "Mac disconnected during sync. Try again.", Toast.LENGTH_SHORT).show()
            } finally {
                pendingAcks.remove(correlationId)
            }
        }
    }

    override suspend fun onResponseReceived(correlationId: String, payload: String, fromDeviceId: String) {
        val deferred = pendingAcks.remove(correlationId)
        if (deferred != null) {
            try {
                val json = org.json.JSONObject(payload)
                val status = json.optString("status")
                val success = (status == "success")
                deferred.complete(success)
                LinkOSLogger.info("Completed pending ACK for correlationId: $correlationId (success=$success)", "ClipboardSync")
            } catch (e: Exception) {
                deferred.complete(false)
            }
        }
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel == MessageChannel.AUTOMATION) {
            try {
                val text = String(payload, Charsets.UTF_8)
                val json = org.json.JSONObject(text)
                if (json.has("buttons")) {
                    val sharedPrefs = getSharedPreferences("linkos_streamdeck", Context.MODE_PRIVATE)
                    sharedPrefs.edit().putString("grid_json", text).apply()
                    LinkOSLogger.info("Saved StreamDeck grid from background AUTOMATION message to SharedPreferences", "Automation")
                }
                val actionType = json.optString("actionType")
                val params = json.optJSONObject("parameters")
                val corrId = params?.optString("correlation_id") ?: ""
                
                LinkOSLogger.info("Automation request received: actionType=$actionType, correlationId=$corrId", "Automation")
                
                serviceScope.launch(Dispatchers.Main) {
                    when (actionType) {
                        "LAUNCH_APP" -> {
                            val appName = params?.optString("app_name")?.lowercase()
                            if (!appName.isNullOrEmpty()) {
                                val launchIntent = getLaunchIntentForAppName(appName)
                                if (launchIntent != null) {
                                    launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(launchIntent)
                                    Toast.makeText(this@LinkOSService, "Launching $appName on phone", Toast.LENGTH_SHORT).show()
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "success")
                                        put("message", "Launched $appName on phone")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                } else {
                                    Toast.makeText(this@LinkOSService, "Could not resolve package for $appName", Toast.LENGTH_SHORT).show()
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "error")
                                        put("message", "Could not resolve package for $appName")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                            }
                        }
                        "TAKE_SCREENSHOT" -> {
                            val activeService = getBoundAccessibilityService()
                            if (activeService != null) {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                    activeService.takeScreenshot(
                                        android.view.Display.DEFAULT_DISPLAY,
                                        mainExecutor,
                                        object : android.accessibilityservice.AccessibilityService.TakeScreenshotCallback {
                                            override fun onSuccess(screenshotResult: android.accessibilityservice.AccessibilityService.ScreenshotResult) {
                                                val hardwareBuffer = screenshotResult.hardwareBuffer
                                                val bitmap = Bitmap.wrapHardwareBuffer(hardwareBuffer, screenshotResult.colorSpace)
                                                if (bitmap != null) {
                                                    val softwareBitmap = bitmap.copy(Bitmap.Config.ARGB_8888, false)
                                                    hardwareBuffer.close()
                                                    
                                                    val downloadDir = File(
                                                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                                                        "LinkOS"
                                                    )
                                                    if (!downloadDir.exists()) {
                                                        downloadDir.mkdirs()
                                                    }
                                                    val finalFile = File(downloadDir, "Screenshot_${System.currentTimeMillis()}.png")
                                                    try {
                                                        java.io.FileOutputStream(finalFile).use { out ->
                                                            softwareBitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                                                        }
                                                        
                                                        android.media.MediaScannerConnection.scanFile(
                                                            this@LinkOSService,
                                                            arrayOf(finalFile.absolutePath),
                                                            null
                                                        ) { path, uri ->
                                                            LinkOSLogger.info("Accessibility screenshot saved: $path -> $uri", "Automation")
                                                        }
                                                        
                                                        Toast.makeText(this@LinkOSService, "✓ Screenshot saved to Download/LinkOS", Toast.LENGTH_SHORT).show()
                                                        
                                                        val replyPayload = org.json.JSONObject().apply {
                                                            put("status", "success")
                                                            put("message", "✓ Screenshot saved to Download/LinkOS")
                                                        }.toString()
                                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                                    } catch (e: Exception) {
                                                        val replyPayload = org.json.JSONObject().apply {
                                                            put("status", "error")
                                                            put("message", "Failed to save screenshot: ${e.message}")
                                                        }.toString()
                                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                                    }
                                                } else {
                                                    hardwareBuffer.close()
                                                    val replyPayload = org.json.JSONObject().apply {
                                                        put("status", "error")
                                                        put("message", "Failed to decode hardware buffer.")
                                                    }.toString()
                                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                                }
                                            }
 
                                            override fun onFailure(errorCode: Int) {
                                                val replyPayload = org.json.JSONObject().apply {
                                                    put("status", "error")
                                                    put("message", "Accessibility screenshot failed with error code: $errorCode")
                                                }.toString()
                                                webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                            }
                                        }
                                    )
                                } else {
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "error")
                                        put("message", "Accessibility screenshot requires Android 11 (API 30) or above.")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                            } else {
                                val replyPayload = org.json.JSONObject().apply {
                                    put("status", "error")
                                    put("message", "Accessibility permission is missing or service is not bound. Please enable LinkOS in Android settings.")
                                }.toString()
                                webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                            }
                        }
                        "SYSTEM_CONTROL" -> {
                            val setting = params?.optString("setting")
                            when (setting) {
                                "lock" -> {
                                    Toast.makeText(this@LinkOSService, "Lock Phone command triggered", Toast.LENGTH_SHORT).show()
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "success")
                                        put("message", "Phone locked")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                                "home" -> {
                                    val activeService = getBoundAccessibilityService()
                                    if (activeService != null) {
                                        val success = activeService.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
                                        val replyPayload = org.json.JSONObject().apply {
                                            if (success) {
                                                put("status", "success")
                                                put("message", "Home gesture triggered")
                                            } else {
                                                put("status", "error")
                                                put("message", "Failed to trigger home gesture")
                                            }
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    } else {
                                        val replyPayload = org.json.JSONObject().apply {
                                            put("status", "error")
                                            put("message", "Accessibility permission is missing or service is not bound.")
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    }
                                }
                                "back" -> {
                                    val activeService = getBoundAccessibilityService()
                                    if (activeService != null) {
                                        val success = activeService.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
                                        val replyPayload = org.json.JSONObject().apply {
                                            if (success) {
                                                put("status", "success")
                                                put("message", "Back gesture triggered")
                                            } else {
                                                put("status", "error")
                                                put("message", "Failed to trigger back gesture")
                                            }
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    } else {
                                        val replyPayload = org.json.JSONObject().apply {
                                            put("status", "error")
                                            put("message", "Accessibility permission is missing or service is not bound.")
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    }
                                }
                                "recents" -> {
                                    val activeService = getBoundAccessibilityService()
                                    if (activeService != null) {
                                        val success = activeService.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_RECENTS)
                                        val replyPayload = org.json.JSONObject().apply {
                                            if (success) {
                                                put("status", "success")
                                                put("message", "Recents gesture triggered")
                                            } else {
                                                put("status", "error")
                                                put("message", "Failed to trigger recents gesture")
                                            }
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    } else {
                                        val replyPayload = org.json.JSONObject().apply {
                                            put("status", "error")
                                            put("message", "Accessibility permission is missing or service is not bound.")
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    }
                                }
                                "volume_up" -> {
                                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                                    audioManager.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_RAISE, android.media.AudioManager.FLAG_SHOW_UI)
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "success")
                                        put("message", "Volume raised")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                                "volume_down" -> {
                                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                                    audioManager.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, android.media.AudioManager.ADJUST_LOWER, android.media.AudioManager.FLAG_SHOW_UI)
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "success")
                                        put("message", "Volume lowered")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                                "mute" -> {
                                    val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
                                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M) {
                                        val isMuted = audioManager.isStreamMute(android.media.AudioManager.STREAM_MUSIC)
                                        audioManager.adjustStreamVolume(android.media.AudioManager.STREAM_MUSIC, if (isMuted) android.media.AudioManager.ADJUST_UNMUTE else android.media.AudioManager.ADJUST_MUTE, android.media.AudioManager.FLAG_SHOW_UI)
                                    } else {
                                        audioManager.setStreamMute(android.media.AudioManager.STREAM_MUSIC, true)
                                    }
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "success")
                                        put("message", "Mute state changed")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                                "paste" -> {
                                    val activeService = getBoundAccessibilityService()
                                    if (activeService != null) {
                                        val success = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                                            activeService.performGlobalAction(12)
                                        } else {
                                            false
                                        }
                                        val replyPayload = org.json.JSONObject().apply {
                                            if (success) {
                                                put("status", "success")
                                                put("message", "Paste action performed")
                                            } else {
                                                put("status", "success")
                                                put("message", "Paste command received (accessibility paste fallback)")
                                            }
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    } else {
                                        val replyPayload = org.json.JSONObject().apply {
                                            put("status", "error")
                                            put("message", "Accessibility permission is missing or service is not bound.")
                                        }.toString()
                                        webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                    }
                                }
                                else -> {
                                    val replyPayload = org.json.JSONObject().apply {
                                        put("status", "error")
                                        put("message", "Unknown system control setting: $setting")
                                    }.toString()
                                    webSocketClient.sendEnvelope("automation", replyPayload, type = "response", correlationId = corrId)
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Error executing automation: ${e.message}", "Automation")
            }
            return
        }

        if (channel == MessageChannel.CAMERA) {
            try {
                val text = String(payload, Charsets.UTF_8)
                val json = org.json.JSONObject(text)
                val action = json.optString("action")
                if (action == "start_camera") {
                    val launchIntent = Intent(this, Class.forName("com.linkos.MainActivity")).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        putExtra("navigate_to", "camera")
                    }
                    startActivity(launchIntent)
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to route camera intent: ${e.message}", "Service")
            }
            return
        }

        if (channel != MessageChannel.CLIPBOARD) return

        try {
            val text = String(payload, Charsets.UTF_8)
            if (text.isEmpty()) return

            // Loop prevention
            if (text == lastSyncedText) return

            val now = System.currentTimeMillis()
            lastSyncedText = text
            lastSyncTimestamp = now
            lastSyncOrigin = "remote"

            LinkOSLogger.info("Remote clipboard received: ${text.take(30)}", "ClipboardSync")

            // Add to history manager
            val historyItem = ClipboardHistoryItem(
                id = UUID.randomUUID().toString(),
                contentType = if (text.startsWith("http")) ClipboardType.URL else ClipboardType.TEXT,
                previewText = text.take(100),
                fullText = text,
                mimeType = "text/plain",
                sourceApp = "Mac Host",
                timestamp = now,
                sizeBytes = text.length
            )
            clipboardHistoryManager.addItem(historyItem)

            // Temporarily remove listener to prevent feedback loop:
            // setPrimaryClip triggers clipListener which would send this text back to Mac
            clipboardManager.removePrimaryClipChangedListener(clipListener)
            val clipData = ClipData.newPlainText("LinkOS Synced Clipboard", text)
            clipboardManager.setPrimaryClip(clipData)
            // Re-add listener after a 150ms delay to ensure the change has fully propagated
            serviceScope.launch {
                kotlinx.coroutines.delay(150)
                clipboardManager.addPrimaryClipChangedListener(clipListener)
            }

        } catch (e: Exception) {
            LinkOSLogger.error("Failed to parse background clipboard packet: ${e.message}", "ClipboardSync")
        }
    }

    private val ACTION_BRIGHTNESS_DOWN = "com.linkos.action.BRIGHTNESS_DOWN"
    private val ACTION_BRIGHTNESS_UP = "com.linkos.action.BRIGHTNESS_UP"
    private val ACTION_VOLUME_DOWN = "com.linkos.action.VOLUME_DOWN"
    private val ACTION_VOLUME_UP = "com.linkos.action.VOLUME_UP"
    private val ACTION_SCREENSHOT = "com.linkos.action.SCREENSHOT"
    private val ACTION_SEND_CLIPBOARD = "com.linkos.action.SEND_CLIPBOARD"
    private val ACTION_DISCONNECT = "com.linkos.action.DISCONNECT"

    private val NOTIFICATION_ID = 8827
    private val CHANNEL_ID = "linkos_background_channel"

    private fun getLaunchIntentForAppName(appName: String): Intent? {
        val pm = packageManager
        val targetLower = appName.lowercase().trim()
        val hardcodedPackage = when {
            targetLower.contains("chrome") -> "com.android.chrome"
            targetLower.contains("instagram") -> "com.instagram.android"
            targetLower.contains("whatsapp") -> "com.whatsapp"
            targetLower.contains("telegram") -> "org.telegram.messenger"
            targetLower.contains("settings") -> "com.android.settings"
            targetLower.contains("calculator") -> "com.google.android.calculator"
            targetLower.contains("youtube") -> "com.google.android.youtube"
            targetLower.contains("spotify") -> "com.spotify.music"
            targetLower.contains("facebook") -> "com.facebook.katana"
            targetLower.contains("maps") -> "com.google.android.apps.maps"
            else -> null
        }
        if (hardcodedPackage != null) {
            val intent = pm.getLaunchIntentForPackage(hardcodedPackage)
            if (intent != null) return intent
        }

        if (targetLower.contains("camera")) {
            return Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE)
        }
        if (targetLower.contains("gallery") || targetLower.contains("photos")) {
            return Intent(Intent.ACTION_VIEW).apply {
                type = "image/*"
            }
        }

        try {
            val packages = pm.getInstalledApplications(android.content.pm.PackageManager.GET_META_DATA)
            for (appInfo in packages) {
                val label = pm.getApplicationLabel(appInfo).toString().lowercase()
                if (label.contains(targetLower) || targetLower.contains(label)) {
                    val intent = pm.getLaunchIntentForPackage(appInfo.packageName)
                    if (intent != null) return intent
                }
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Error searching installed packages: ${e.message}", "Automation")
        }
        
        return try {
            pm.getLaunchIntentForPackage(appName)
        } catch (e: Exception) {
            null
        }
    }

    private fun createNotification(): Notification {
        val channelName = "LinkOS Background Sync"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val chan = NotificationChannel(CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(chan)
        }

        val isConnected = connectionStateManager.phase.value == com.linkos.core.network.ConnectionPhase.CONNECTED
        val pairedName = connectionStateManager.connectedDevice.value?.name ?: "Hritesh's MacBook Pro"
        val statusText = if (isConnected) {
            "Connected to Mac ($pairedName)"
        } else if (webSocketClient.isManualDisconnect) {
            "Disconnected"
        } else {
            "Searching for Mac..."
        }

        val collapsedViews = RemoteViews(packageName, R.layout.notification_linkos)
        collapsedViews.setTextViewText(R.id.notification_title, "LinkOS Active")
        collapsedViews.setTextViewText(R.id.notification_subtitle, statusText)

        val expandedViews = RemoteViews(packageName, R.layout.notification_linkos_expanded)
        expandedViews.setTextViewText(R.id.notification_title, "LinkOS Active")
        expandedViews.setTextViewText(R.id.notification_subtitle, statusText)

        fun makeActionPendingIntent(action: String): android.app.PendingIntent {
            val intent = Intent(this, LinkOSService::class.java).apply {
                this.action = action
            }
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            } else {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT
            }
            return android.app.PendingIntent.getService(this, action.hashCode(), intent, flags)
        }

        val sendClipboardIntent = Intent(this, ClipboardSyncActivity::class.java).apply {
            action = ACTION_SEND_CLIPBOARD
        }
        val sendClipboardPendingIntent = android.app.PendingIntent.getActivity(
            this,
            ACTION_SEND_CLIPBOARD.hashCode(),
            sendClipboardIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE
            } else {
                android.app.PendingIntent.FLAG_UPDATE_CURRENT
            }
        )

        expandedViews.setOnClickPendingIntent(R.id.btn_brightness_down, makeActionPendingIntent(ACTION_BRIGHTNESS_DOWN))
        expandedViews.setOnClickPendingIntent(R.id.btn_brightness_up, makeActionPendingIntent(ACTION_BRIGHTNESS_UP))
        expandedViews.setOnClickPendingIntent(R.id.btn_volume_down, makeActionPendingIntent(ACTION_VOLUME_DOWN))
        expandedViews.setOnClickPendingIntent(R.id.btn_volume_up, makeActionPendingIntent(ACTION_VOLUME_UP))
        expandedViews.setOnClickPendingIntent(R.id.btn_screenshot, makeActionPendingIntent(ACTION_SCREENSHOT))
        expandedViews.setOnClickPendingIntent(R.id.btn_send_to_mac, sendClipboardPendingIntent)
        expandedViews.setOnClickPendingIntent(R.id.btn_disconnect, makeActionPendingIntent(ACTION_DISCONNECT))

        if (!isConnected) {
            expandedViews.setViewVisibility(R.id.row_1, android.view.View.GONE)
            expandedViews.setViewVisibility(R.id.row_2, android.view.View.GONE)
        } else {
            expandedViews.setViewVisibility(R.id.row_1, android.view.View.VISIBLE)
            expandedViews.setViewVisibility(R.id.row_2, android.view.View.VISIBLE)
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(collapsedViews)
            .setCustomBigContentView(expandedViews)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(true)

        return builder.build()
    }

    private fun isAccessibilityEnabled(): Boolean {
        val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager
        val enabledServices = am.getEnabledAccessibilityServiceList(android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_GENERIC)
        return enabledServices?.any { it.resolveInfo.serviceInfo.packageName == packageName } ?: false
    }

    private suspend fun getBoundAccessibilityService(): LinkOSAccessibilityService? {
        if (!isAccessibilityEnabled()) return null
        for (i in 0 until 15) {
            val service = LinkOSAccessibilityService.instance
            if (service != null) return service
            kotlinx.coroutines.delay(100)
        }
        return LinkOSAccessibilityService.instance
    }

    private var accessibilityObserver: android.database.ContentObserver? = null

    private fun registerAccessibilityObserver() {
        val uri = android.provider.Settings.Secure.getUriFor(android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
        accessibilityObserver = object : android.database.ContentObserver(android.os.Handler(android.os.Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                super.onChange(selfChange)
                LinkOSLogger.info("Accessibility settings change detected, checking capability...", "Automation")
                val isEnabled = isAccessibilityEnabled()
                sendCapabilitiesToMac(isEnabled)
            }
        }
        contentResolver.registerContentObserver(uri, false, accessibilityObserver!!)
    }

    private fun unregisterAccessibilityObserver() {
        accessibilityObserver?.let {
            contentResolver.unregisterContentObserver(it)
        }
        accessibilityObserver = null
    }

    private fun sendCapabilitiesToMac(isEnabled: Boolean) {
        val caps = mutableListOf<String>()
        if (isEnabled) {
            caps.add("ACCESSIBILITY_ENABLED")
        }
        val payload = org.json.JSONObject().apply {
            put("action", "set_capabilities")
            val arr = org.json.JSONArray()
            caps.forEach { arr.put(it) }
            put("capabilities", arr)
        }.toString()
        serviceScope.launch {
            webSocketClient.sendEnvelope("session", payload, type = "event")
        }
    }
}
