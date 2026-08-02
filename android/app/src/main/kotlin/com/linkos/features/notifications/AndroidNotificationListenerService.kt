package com.linkos.features.notifications

import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

@AndroidEntryPoint
class AndroidNotificationListenerService : NotificationListenerService() {

    @Inject
    lateinit var connectionStateManager: ConnectionStateManager

    @Inject
    lateinit var webSocketClient: WebSocketClient

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    override fun onCreate() {
        super.onCreate()
        
        // Listen for notification action callbacks from macOS
        serviceScope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                try {
                    val text = String(bytes, Charsets.UTF_8)
                    if (text.startsWith("{")) {
                        val json = JSONObject(text)
                        val channelStr = json.optString("channel")
                        if (channelStr == "notifications_action") {
                            val payloadStr = json.optString("payload")
                            handleNotificationAction(payloadStr)
                        }
                    }
                } catch (e: Exception) {
                    // Ignore
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? {
        LinkOSLogger.info("Notification mirroring service bound", "Notifications")
        return super.onBind(intent)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        val notification = sbn?.notification ?: return
        val extras = notification.extras
        
        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val text = extras.getCharSequence("android.text")?.toString() ?: ""
        val appName = sbn.packageName
        
        if (title.isBlank() && text.isBlank()) return
        
        val payload = JSONObject().apply {
            put("id", sbn.key)
            put("app_name", appName)
            put("title", title)
            put("body", text)
            put("priority", notification.priority)
            put("timestamp_ms", sbn.postTime)
        }
        
        try {
            connectionStateManager.routeMessage(
                channel = MessageChannel.NOTIFICATIONS,
                payload = payload.toString().toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
            LinkOSLogger.debug("Mirrored notification to macOS: $title", "Notifications")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to forward notification: ${e.message}", "Notifications")
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        val sbnKey = sbn?.key ?: return
        val payload = JSONObject().apply {
            put("action", "dismiss")
            put("id", sbnKey)
        }
        
        try {
            connectionStateManager.routeMessage(
                channel = MessageChannel.NOTIFICATIONS,
                payload = payload.toString().toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        } catch (e: Exception) {
            // Ignore
        }
    }

    // MARK: - Notification Action Handlers

    private fun handleNotificationAction(payloadStr: String) {
        try {
            val json = JSONObject(payloadStr)
            val action = json.optString("action")
            val id = json.optString("id")
            
            if (action == "dismiss") {
                cancelNotification(id)
                LinkOSLogger.info("Notification dismissed from macOS: $id", "Notifications")
            } else if (action == "reply") {
                val replyText = json.optString("text")
                if (replyText.isNotEmpty()) {
                    sendNotificationReply(id, replyText)
                }
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to execute notification action: ${e.message}", "Notifications")
        }
    }

    private fun sendNotificationReply(key: String, replyText: String) {
        val activeSbns = activeNotifications ?: return
        val sbn = activeSbns.firstOrNull { it.key == key } ?: return
        val actions = sbn.notification.actions ?: return
        
        for (action in actions) {
            val remoteInputs = action.remoteInputs ?: continue
            for (remoteInput in remoteInputs) {
                if (remoteInput.allowFreeFormInput) {
                    val intent = Intent().apply {
                        val bundle = android.os.Bundle()
                        bundle.putCharSequence(remoteInput.resultKey, replyText)
                        android.app.RemoteInput.addResultsToIntent(arrayOf(remoteInput), this, bundle)
                    }
                    try {
                        action.actionIntent.send(this, 0, intent)
                        LinkOSLogger.info("Notification reply sent successfully", "Notifications")
                        return
                    } catch (e: Exception) {
                        LinkOSLogger.error("Failed to send notification pending intent: ${e.message}", "Notifications")
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
    }
}
