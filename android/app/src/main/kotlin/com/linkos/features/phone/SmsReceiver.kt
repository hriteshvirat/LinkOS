package com.linkos.features.phone

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class SmsReceiver : BroadcastReceiver() {

    @Inject
    lateinit var webSocketClient: WebSocketClient

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        
        try {
            val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
            for (msg in messages) {
                val body = msg.messageBody ?: continue
                
                // Matches 4-8 digit OTP verification codes
                val regex = Regex("\\b\\d{4,8}\\b")
                val match = regex.find(body)
                if (match != null) {
                    val otpCode = match.value
                    
                    // Send directly to Mac's clipboard
                    val payload = org.json.JSONObject().apply {
                        put("text", otpCode)
                        put("action", "sync")
                    }
                    webSocketClient.sendEnvelope("clipboard", payload.toString(), type = "request")
                    LinkOSLogger.info("OTP verification code mirrored to Mac clipboard: $otpCode", "OtpSync")
                }
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to parse SMS OTP code: ${e.message}", "OtpSync")
        }
    }
}
