import Foundation

/// Routes incoming messages to the appropriate plugin based on channel.
/// Also handles protocol-level messages (heartbeat, pairing, permissions).
actor MessageRouter {
    
    private weak var pluginManager: PluginManager?
    private var handlers: [String: (LinkOSMessageEnvelope) async -> Void] = [:]
    private let logger = LinkOSLogger.shared
    
    init(pluginManager: PluginManager? = nil) {
        self.pluginManager = pluginManager
    }
    
    // MARK: - Registration
    
    /// Register a handler for a specific channel (for core protocol messages).
    func registerHandler(channel: String, handler: @escaping (LinkOSMessageEnvelope) async -> Void) {
        handlers[channel] = handler
        logger.debug("Registered handler for channel: \(channel)", category: .protocol_)
    }
    
    // MARK: - Routing
    
    /// Route an incoming raw message. Deserializes the envelope and dispatches.
    func route(rawData: Data, from deviceId: String) async {
        // Deserialize the envelope
        guard let envelope = deserializeEnvelope(rawData, deviceId: deviceId) else {
            logger.warning("Failed to deserialize message from \(deviceId)", category: .protocol_)
            return
        }
        
        // Try channel-specific handler first (for core protocol)
        if let handler = handlers[envelope.channel] {
            await handler(envelope)
            return
        }
        
        // Propagate to ConnectionStateManager subscribers
        var channelName = envelope.channel
        if channelName == "files" {
            channelName = "fileTransfer"
        }
        if let channel = MessageChannel(rawValue: channelName) {
            await ConnectionStateManager.shared.routeMessage(channel: channel, payload: envelope.payload, from: deviceId)
        }
        
        // Route to plugins
        await pluginManager?.routeMessage(envelope)
    }
    
    // MARK: - Serialization
    
    private func deserializeEnvelope(_ data: Data, deviceId: String) -> LinkOSMessageEnvelope? {
        // In production, this would use Protobuf deserialization.
        // For now, use a simple JSON-based envelope for bootstrapping.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageId = json["message_id"] as? String,
              let typeRaw = json["type"] as? String,
              let channel = json["channel"] as? String else {
            return nil
        }
        
        let type: LinkOSMessageEnvelope.MessageEnvelopeType
        switch typeRaw {
        case "request": type = .request
        case "response": type = .response
        case "event": type = .event
        case "stream": type = .stream
        case "ack": type = .ack
        default: type = .event
        }
        
        let payload = (json["payload"] as? String)?.data(using: .utf8) ?? Data()
        
        return LinkOSMessageEnvelope(
            messageId: messageId,
            type: type,
            channel: channel,
            timestamp: Date(),
            payload: payload,
            deviceId: deviceId,
            correlationId: json["correlation_id"] as? String
        )
    }
    
    /// Create a request envelope.
    static func createRequest(
        channel: String,
        payload: Data,
        correlationId: String? = nil
    ) -> Data {
        let envelope: [String: Any] = [
            "message_id": UUID().uuidString,
            "type": "request",
            "channel": channel,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "payload": String(data: payload, encoding: .utf8) ?? "",
            "correlation_id": correlationId ?? "",
            "protocol_version": ProtocolConstants.protocolVersion,
            "device_id": DeviceIdentity.deviceId,
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
    
    /// Create a response envelope.
    static func createResponse(
        channel: String,
        payload: Data,
        correlationId: String? = nil
    ) -> Data {
        let envelope: [String: Any] = [
            "message_id": UUID().uuidString,
            "type": "response",
            "channel": channel,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "payload": String(data: payload, encoding: .utf8) ?? "",
            "correlation_id": correlationId ?? "",
            "protocol_version": ProtocolConstants.protocolVersion,
            "device_id": DeviceIdentity.deviceId,
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
    
    /// Create an event envelope.
    static func createEvent(channel: String, payload: Data) -> Data {
        let envelope: [String: Any] = [
            "message_id": UUID().uuidString,
            "type": "event",
            "channel": channel,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "payload": String(data: payload, encoding: .utf8) ?? "",
            "protocol_version": ProtocolConstants.protocolVersion,
            "device_id": DeviceIdentity.deviceId,
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }
}

/// Multiplexes multiple logical channels over a single transport connection.
actor ChannelMultiplexer {
    
    private var channelSubscriptions: [String: Set<String>] = [:]  // channel -> set of deviceIds
    private let logger = LinkOSLogger.shared
    
    /// Subscribe a device to a channel.
    func subscribe(deviceId: String, to channel: String) {
        channelSubscriptions[channel, default: []].insert(deviceId)
        logger.debug("Device \(deviceId) subscribed to \(channel)", category: .protocol_)
    }
    
    /// Unsubscribe a device from a channel.
    func unsubscribe(deviceId: String, from channel: String) {
        channelSubscriptions[channel]?.remove(deviceId)
    }
    
    /// Unsubscribe a device from all channels (on disconnect).
    func unsubscribeAll(deviceId: String) {
        for channel in channelSubscriptions.keys {
            channelSubscriptions[channel]?.remove(deviceId)
        }
    }
    
    /// Get all devices subscribed to a channel.
    func subscribers(for channel: String) -> Set<String> {
        channelSubscriptions[channel] ?? []
    }
}
