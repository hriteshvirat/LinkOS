package com.linkos.features.notifications

import android.content.Intent
import android.os.IBinder
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.MessageChannel
import dagger.hilt.android.AndroidEntryPoint
import org.json.JSONObject
import javax.inject.Inject

@AndroidEntryPoint
class AndroidNotificationListenerService : NotificationListenerService() {

    @Inject
    lateinit var connectionStateManager: ConnectionStateManager

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
}
