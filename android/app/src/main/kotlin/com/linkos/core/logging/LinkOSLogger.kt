package com.linkos.core.logging

import android.util.Log
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.Date
import java.util.concurrent.ConcurrentLinkedQueue

enum class LogLevel { DEBUG, INFO, WARNING, ERROR, CRITICAL }

@Serializable
data class LogEntry(
    val timestampMs: Long,
    val level: LogLevel,
    val category: String,
    val message: String,
    val metadata: Map<String, String>? = null
)

/**
 * Android Structured Logger matching macOS LinkOSLogger behavior.
 */
object LinkOSLogger {
    private const val TAG_PREFIX = "LinkOS"
    private val buffer = ConcurrentLinkedQueue<LogEntry>()
    private const val MAX_BUFFER_SIZE = 10_000

    var onLogForwarded: ((level: LogLevel, message: String, category: String, metadata: Map<String, String>?) -> Unit)? = null

    fun debug(message: String, category: String, metadata: Map<String, String>? = null) {
        log(LogLevel.DEBUG, message, category, metadata)
    }

    fun info(message: String, category: String, metadata: Map<String, String>? = null) {
        log(LogLevel.INFO, message, category, metadata)
    }

    fun warning(message: String, category: String, metadata: Map<String, String>? = null) {
        log(LogLevel.WARNING, message, category, metadata)
    }

    fun error(message: String, category: String, error: Throwable? = null, metadata: Map<String, String>? = null) {
        val meta = metadata?.toMutableMap() ?: mutableMapOf()
        if (error != null) meta["error"] = error.localizedMessage ?: error.toString()
        log(LogLevel.ERROR, message, category, meta)
    }

    private fun log(level: LogLevel, message: String, category: String, metadata: Map<String, String>?) {
        val tag = "$TAG_PREFIX:$category"
        val fullMsg = if (metadata.isNullOrEmpty()) message else "$message | $metadata"

        when (level) {
            LogLevel.DEBUG -> Log.d(tag, fullMsg)
            LogLevel.INFO -> Log.i(tag, fullMsg)
            LogLevel.WARNING -> Log.w(tag, fullMsg)
            LogLevel.ERROR, LogLevel.CRITICAL -> Log.e(tag, fullMsg)
        }

        val entry = LogEntry(
            timestampMs = System.currentTimeMillis(),
            level = level,
            category = category,
            message = message,
            metadata = metadata
        )
        buffer.add(entry)
        while (buffer.size > MAX_BUFFER_SIZE) {
            buffer.poll()
        }

        if (level == LogLevel.WARNING || level == LogLevel.ERROR || level == LogLevel.CRITICAL) {
            onLogForwarded?.invoke(level, message, category, metadata)
        }
    }

    fun exportLogsJson(): String {
        val json = Json { prettyPrint = true }
        val sanitized = buffer.map { entry ->
            val sensitiveKeys = setOf("api_key", "token", "password", "secret", "private_key")
            val cleanedMeta = entry.metadata?.mapValues { (k, v) ->
                if (sensitiveKeys.contains(k.lowercase())) "[REDACTED]" else v
            }
            entry.copy(metadata = cleanedMeta)
        }
        return json.encodeToString(sanitized)
    }

    fun getBuffer(): List<LogEntry> = buffer.toList()
    
    fun clearBuffer() {
        buffer.clear()
    }
    
    fun generatePairingReport(currentConnectionState: String, lastFailureStage: String?): String {
        return generateFeatureLogReport(currentConnectionState)
    }

    fun generateFeatureLogReport(currentConnectionState: String): String {
        val sb = java.lang.StringBuilder()
        sb.append("========================\n")
        sb.append("LINKOS SYSTEM DIAGNOSTICS\n")
        sb.append("========================\n\n")
        sb.append("Android Version: ${android.os.Build.VERSION.RELEASE}\n")
        sb.append("Device: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}\n")
        sb.append("Connection State: $currentConnectionState\n\n")
        sb.append("------------------------\n\n")
        
        val logs = getBuffer()
        val sdf = java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.getDefault())
        
        for (log in logs) {
            val msg = log.message
            val cat = log.category
            
            // Filter out stages, raw frame and verbose socket spam
            if (msg.contains("[RAW FRAME") || msg.contains("[TRANSPORT]") || msg.contains("[STAGE ") || msg.contains("STAGE ") || msg.contains("JSON PARSE") || msg.contains("mDNS")) {
                continue
            }
            
            val isFeature = when (cat) {
                "Input" -> msg.contains("[Trackpad]") || msg.contains("[INPUT]") || msg.contains("Trackpad")
                "Clipboard" -> msg.contains("[Clipboard]") || msg.contains("Clipboard")
                "Media" -> msg.contains("[RemoteDesktop]") || msg.contains("RemoteDesktop") || msg.contains("Screen")
                "Files" -> msg.contains("[Files]") || msg.contains("File")
                "Security" -> msg.contains("Permission")
                "App", "Network" -> msg.contains("Connected") || msg.contains("Disconnected") || msg.contains("activated") || msg.contains("deactivated")
                else -> false
            }
            
            if (isFeature) {
                val logTime = sdf.format(Date(log.timestampMs))
                sb.append("$logTime [$cat] $msg\n")
            }
        }
        return sb.toString()
    }
}
