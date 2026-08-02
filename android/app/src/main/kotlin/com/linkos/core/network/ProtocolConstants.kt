package com.linkos.core.network

/**
 * Centralised protocol constants for the LinkOS communication layer.
 * Prevents typo-based bugs by providing compile-time checked string constants.
 */
object ProtocolConstants {

    // Protocol Version
    const val PROTOCOL_VERSION = 2

    // Feature Flags (advertised during pairing handshake)
    object FeatureFlags {
        const val RESUMABLE_TRANSFERS = "resumableTransfers"
        const val THUMBNAIL_CACHE = "thumbnailCache"
        const val MACRO_SYNC = "macroSync"
        const val BATTERY_TELEMETRY = "batteryTelemetry"
    }

    // Channel Names
    object Channel {
        const val CURSOR = "cursor"
        const val KEYBOARD = "keyboard"
        const val CLIPBOARD = "clipboard"
        const val FILES = "files"
        const val FILE_TRANSFER = "fileTransfer"
        const val REMOTE_DESKTOP = "remotedesktop"
        const val AUDIO = "audio"
        const val CAMERA = "camera"
        const val NOTIFICATIONS = "notifications"
        const val PHONE = "phone"
        const val HANDOFF = "handoff"
        const val MEDIA_CONTROL = "mediaControl"
        const val AUTOMATION = "automation"
        const val STREAM_DECK = "streamdeck"
        const val HEARTBEAT = "heartbeat"
        const val SESSION = "session"
        const val DASHBOARD = "dashboard"
    }

    // Message Types
    object MessageType {
        const val REQUEST = "request"
        const val RESPONSE = "response"
        const val EVENT = "event"
        const val STREAM = "stream"
        const val ACK = "ack"
    }

    // File Transfer Actions
    object FileAction {
        const val LIST = "list"
        const val UPLOAD_CHUNK = "upload_chunk"
        const val OPERATION = "operation"
        const val DOWNLOAD = "download"
        const val FILE_RECEIVED = "file_received"
        const val QUERY_CHUNKS = "query_chunks"
        const val QUERY_CHUNKS_RESPONSE = "query_chunks_response"
    }

    // Session Actions
    object SessionAction {
        const val DISCONNECT = "disconnect"
        const val SET_DEVICE_NAME = "set_device_name"
        const val SET_CAPABILITIES = "set_capabilities"
    }

    // Heartbeat
    object Heartbeat {
        const val PING = "ping"
        const val PONG = "pong"
        const val INTERVAL_MS = 4000L
        const val TIMEOUT_MS = 8000L
    }

    // Transfer
    object Transfer {
        const val WINDOW_SIZE = 16
        const val MAX_RETRIES = 3
        const val CHUNK_ACK_TIMEOUT_MS = 20_000L
    }

    // Telemetry
    object Telemetry {
        const val INTERVAL_MS = 5000L
    }
}
