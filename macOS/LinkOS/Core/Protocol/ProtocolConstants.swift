import Foundation

/// Centralised protocol constants for the LinkOS communication layer.
/// Prevents typo-based bugs by providing compile-time checked string constants.
enum ProtocolConstants {
    
    // MARK: - Protocol Version
    
    static let protocolVersion = 2
    
    // MARK: - Feature Flags (advertised during pairing handshake)
    
    struct FeatureFlags {
        static let resumableTransfers = "resumableTransfers"
        static let thumbnailCache = "thumbnailCache"
        static let macroSync = "macroSync"
        static let batteryTelemetry = "batteryTelemetry"
    }
    
    // MARK: - Channel Names
    
    struct Channel {
        static let cursor = "cursor"
        static let keyboard = "keyboard"
        static let clipboard = "clipboard"
        static let files = "files"
        static let fileTransfer = "fileTransfer"
        static let remoteDesktop = "remotedesktop"
        static let audio = "audio"
        static let camera = "camera"
        static let notifications = "notifications"
        static let phone = "phone"
        static let handoff = "handoff"
        static let mediaControl = "mediaControl"
        static let automation = "automation"
        static let streamDeck = "streamdeck"
        static let heartbeat = "heartbeat"
        static let session = "session"
        static let dashboard = "dashboard"
    }
    
    // MARK: - Message Types
    
    struct MessageType {
        static let request = "request"
        static let response = "response"
        static let event = "event"
        static let stream = "stream"
        static let ack = "ack"
    }
    
    // MARK: - File Transfer Actions
    
    struct FileAction {
        static let list = "list"
        static let uploadChunk = "upload_chunk"
        static let operation = "operation"
        static let download = "download"
        static let fileReceived = "file_received"
        static let queryChunks = "query_chunks"
        static let queryChunksResponse = "query_chunks_response"
    }
    
    // MARK: - Session Actions
    
    struct SessionAction {
        static let disconnect = "disconnect"
        static let setDeviceName = "set_device_name"
        static let setCapabilities = "set_capabilities"
    }
    
    // MARK: - Heartbeat
    
    struct Heartbeat {
        static let ping = "ping"
        static let pong = "pong"
        static let intervalSeconds: TimeInterval = 4.0
        static let timeoutSeconds: TimeInterval = 8.0
    }
    
    // MARK: - Transfer
    
    struct Transfer {
        static let windowSize = 16
        static let maxRetries = 3
        static let chunkAckTimeoutSeconds: TimeInterval = 20.0
    }
    
    // MARK: - Telemetry
    
    struct Telemetry {
        static let intervalSeconds: TimeInterval = 5.0
    }
}
