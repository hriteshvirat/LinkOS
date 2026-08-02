package com.linkos.features.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.MessageChannel
import dagger.hilt.android.AndroidEntryPoint
import org.json.JSONObject
import javax.inject.Inject

@AndroidEntryPoint
class PhoneCallReceiver : BroadcastReceiver() {

    @Inject
    lateinit var connectionStateManager: ConnectionStateManager

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return
        
        val stateStr = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
        val incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: "Unknown Caller"
        
        val state = when (stateStr) {
            TelephonyManager.EXTRA_STATE_RINGING -> "RINGING"
            TelephonyManager.EXTRA_STATE_OFFHOOK -> "OFFHOOK"
            TelephonyManager.EXTRA_STATE_IDLE -> "IDLE"
            else -> "UNKNOWN"
        }
        
        val payload = JSONObject().apply {
            put("action", "call_state")
            put("state", state)
            put("number", incomingNumber)
            put("timestamp_ms", System.currentTimeMillis())
        }
        
        try {
            connectionStateManager.routeMessage(
                channel = MessageChannel.PHONE,
                payload = payload.toString().toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
            LinkOSLogger.info("Phone call state broadcasted: $state ($incomingNumber)", "PhoneIntegration")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to forward call state: ${e.message}", "PhoneIntegration")
        }
    }
}
