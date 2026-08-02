import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import Combine

/// WebSocket server for the control channel.
/// Handles incoming connections from Android devices, upgrades HTTP to WebSocket,
/// parses pairing handshakes, and dispatches messages to AppState & MessageRouter.
@MainActor
final class WebSocketServer {
    public static let shared = WebSocketServer()
    
    private var group: EventLoopGroup?
    private var channel: Channel?
    private var connections: [String: WebSocketConnection] = [:]
    private let logger = LinkOSLogger.shared
    private var activeCaptureService: ScreenCaptureService?
    private var cancellables = Set<AnyCancellable>()
    private var isCurrentlyListening = false
    
    public var activeConnectedDeviceConnection: WebSocketConnection? {
        return connections.values.first { !$0.isInput }
    }
    
    let port: Int
    
    init(port: Int = 52637) {
        self.port = port
    }
    
    func isListening() -> Bool {
        return isCurrentlyListening && channel != nil
    }
    
    // MARK: - Server Lifecycle
    
    func start() async throws {
        guard channel == nil else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let webSocketHandler = LinkOSWebSocketHandler(server: self)
                let httpHandler = HTTPByteBufferResponsePartHandler()
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 10 * 1024 * 1024,
                    shouldUpgrade: { channel, head in
                        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, head in
                        let isInput = head.uri.hasPrefix("/input")
                        webSocketHandler.isInputChannel = isInput
                        return channel.pipeline.addHandler(webSocketHandler)
                    }
                )
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { context in
                        LinkOSLogger.shared.info("[TRANSPORT] WEBSOCKET UPGRADE COMPLETE", category: .network)
                        _ = context.pipeline.removeHandler(httpHandler)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: config
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
        
        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        self.channel = channel
        self.isCurrentlyListening = true
        
        logger.info("WebSocket server listening on port \(port)", category: .network)
    }
    
    func stop() async {
        try? await channel?.close()
        try? await group?.shutdownGracefully()
        channel = nil
        group = nil
        isCurrentlyListening = false
        logger.info("WebSocket server stopped", category: .network)
    }
    
    // MARK: - Connection Management
    
    func addConnection(_ connection: WebSocketConnection) {
        connections[connection.id] = connection
        logger.info("[TRANSPORT] CONNECTION REGISTERED (connId: \(connection.id), isInput: \(connection.isInput))", category: .network)
        if !connection.isInput {
            logger.info("[STAGE 2] Socket accepted (WebSocket connection added: \(connection.id))", category: .network)
        }
    }
    
    func removeConnection(_ id: String) {
        guard let connection = connections[id] else { return }
        connections.removeValue(forKey: id)
        logger.info("WebSocket connection removed: \(id) (isInput: \(connection.isInput))", category: .network)
        if connection.isInput {
            return
        }
        if let service = self.activeCaptureService {
            Task {
                await service.stopCapture()
            }
            self.activeCaptureService = nil
        }
        if let deviceId = connection.deviceId {
            let hasOtherConnection = connections.values.contains { $0.id != id && $0.deviceId == deviceId }
            if !hasOtherConnection {
                AppState.shared.handleActiveDeviceDisconnected(deviceId: deviceId)
            } else {
                logger.info("[WebSocket] Preserving active session; stale connection \(id) for device \(deviceId) disconnected", category: .network)
            }
        } else {
            let state = AppState.shared.pairingState
            if state != .pinGenerated && state != .qrGenerated {
                AppState.shared.disconnectActiveDevice()
            }
        }
        if AppState.shared.activePendingConnection?.id == id {
            let state = AppState.shared.pairingState
            if state != .pinGenerated && state != .qrGenerated {
                AppState.shared.destroySession(reason: "Active pending connection disconnected")
            } else {
                AppState.shared.activePendingConnection = nil
            }
        }
    }

    func associateConnection(_ connection: WebSocketConnection, withDeviceId deviceId: String) {
        logger.info("[WebSocket] Associating connection \(connection.id) with deviceId: \(deviceId)", category: .network)
        connection.setDeviceId(deviceId)
        
        let staleConnectionIds = connections.filter { $0.value.id != connection.id && $0.value.deviceId == deviceId }.map { $0.key }
        for connId in staleConnectionIds {
            if let conn = connections[connId] {
                logger.info("[WebSocket] Closing duplicate/stale connection \(conn.id) for deviceId: \(deviceId)", category: .network)
                Task {
                    _ = try? await conn.channel.close()
                }
                connections.removeValue(forKey: connId)
            }
        }
    }

    func disconnectAllConnections() async {
        let disconnectPayload: [String: Any] = [
            "action": "disconnect"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: disconnectPayload) {
            let msg = MessageRouter.createEvent(channel: "session", payload: data)
            await broadcast(msg)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for (_, connection) in connections {
            _ = try? await connection.channel.close()
        }
    }
    
    func handleIncomingData(_ data: Data, from connection: WebSocketConnection) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        // Extract effective payload JSON if wrapped in channel envelope {"channel": "...", "payload": "..." | {...}}
        var effectiveJson = json
        if let payloadStr = json["payload"] as? String,
           let payloadData = payloadStr.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
            effectiveJson = nested
        } else if let nested = json["payload"] as? [String: Any] {
            effectiveJson = nested
        }
        
        let channel = json["channel"] as? String ?? effectiveJson["channel"] as? String
        if channel == "heartbeat" {
            if effectiveJson["type"] as? String == "ping" {
                let responsePayload = "{\"type\":\"pong\"}".data(using: .utf8)!
                let messageId = json["message_id"] as? String ?? UUID().uuidString
                if let responseEnvelope = try? MessageRouter.createResponse(channel: "heartbeat", payload: responsePayload, correlationId: messageId) {
                    try? await connection.send(responseEnvelope)
                }
            }
            return
        }
        
        let action = json["action"] as? String ?? effectiveJson["action"] as? String
        if let action = action {
            if action == "start" {
                if !PermissionManager.shared.hasPermission(.screenRecording) {
                    LinkOSLogger.shared.info("[RemoteDesktop] Screen recording permission missing. Waiting...", category: .media)
                    
                    // Tell the Android client we are waiting for permission
                    let waitPayload: [String: Any] = [
                        "channel": "remotedesktop",
                        "status": "waiting_for_permission"
                    ]
                    if let waitData = try? JSONSerialization.data(withJSONObject: waitPayload) {
                        try? await connection.send(waitData)
                    }
                    
                    // Open preferences automatically
                    PermissionManager.shared.requestPermissionExplicitly(.screenRecording)
                    
                    // Cancel previous observations
                    self.cancellables.removeAll()
                    
                    // Observe changes
                    PermissionManager.shared.$isScreenRecordingGranted
                        .filter { $0 == true }
                        .first()
                        .receive(on: RunLoop.main)
                        .sink { [weak self] _ in
                            guard let self = self else { return }
                            Task {
                                self.startScreenCapture(on: connection)
                            }
                        }
                        .store(in: &cancellables)
                    return
                }
                
                self.startScreenCapture(on: connection)
                return
            } else if action == "stop" {
                if let service = self.activeCaptureService {
                    Task {
                        await service.stopCapture()
                    }
                    self.activeCaptureService = nil
                }
                return
            } else if action == "disconnect" {
                AppState.shared.disconnectActiveDevice()
                return
            } else if action == "set_device_name" {
                // Handle identity sync from Android onboarding
                if let name = effectiveJson["name"] as? String ?? json["name"] as? String {
                    ConnectionStateManager.shared.updateDeviceName(name)
                    AppState.shared.connectedDeviceName = name
                    logger.info("[Identity] Device name updated to: \(name)", category: .network)
                }
                return
            } else if action == "set_capabilities" {
                if let capsArray = effectiveJson["capabilities"] as? [String] ?? json["capabilities"] as? [String] {
                    let capsSet = Set(capsArray)
                    ConnectionStateManager.shared.updateDeviceCapabilities(capsSet)
                }
                return
            } else if action == "move" || action == "click" || action == "scroll" || action == "launchpad" || action == "media" || action == "keyboard" || action == "zoom" || action == "mission_control" || action == "app_expose" || action == "spaces_left" || action == "spaces_right" {
                GestureInterpreter.shared.interpret(json: effectiveJson)
                return
            }
        }
        
        let type = json["type"] as? String ?? effectiveJson["type"] as? String
        guard let type = type else {
            return
        }
        
        if type == "PAIRING_INIT" {
            let initiator = effectiveJson["initiator"] as? String ?? json["initiator"] as? String ?? "android"
            let method = effectiveJson["method"] as? String ?? json["method"] as? String ?? "PIN"
            Task { @MainActor in
                AppState.shared.activePendingConnection = connection
                AppState.shared.handlePairingInit(initiator: initiator, method: method)
            }
        }
        
        if type == "PAIRING_REQUEST" {
            let deviceId = (effectiveJson["deviceId"] as? String) ?? (json["deviceId"] as? String) ?? connection.id
            associateConnection(connection, withDeviceId: deviceId)
            
            let deviceName = (effectiveJson["deviceName"] as? String) ?? (json["deviceName"] as? String) ?? "Android Device"
            let model = (effectiveJson["model"] as? String) ?? (json["model"] as? String) ?? "Android"
            let manufacturer = (effectiveJson["manufacturer"] as? String) ?? (json["manufacturer"] as? String) ?? "Generic"
            let osVersion = (effectiveJson["osVersion"] as? String) ?? (json["osVersion"] as? String) ?? "Android"
            let pairingCode = (effectiveJson["pairingCode"] as? String) ?? (json["pairingCode"] as? String)
            
            let req = PendingPairingRequest(
                id: deviceId,
                deviceName: deviceName,
                deviceModel: model,
                manufacturer: manufacturer,
                osVersion: osVersion,
                pairingCode: pairingCode
            )
            Task { @MainActor in
                AppState.shared.activePendingConnection = connection
                AppState.shared.requestPairing(from: req)
            }
        }
        
        if type == "KEY_EXCHANGE" {
            let deviceId = (effectiveJson["deviceId"] as? String) ?? (json["deviceId"] as? String) ?? connection.deviceId ?? connection.id
            associateConnection(connection, withDeviceId: deviceId)
            
            let pubKeyBase64 = (effectiveJson["publicKey"] as? String) ?? (json["publicKey"] as? String)
            guard let pubKeyBase64 = pubKeyBase64,
                  let pubKeyData = Data(base64Encoded: pubKeyBase64),
                  let peerPubKey = try? E2EEncryption.deserializePublicKey(pubKeyData) else {
                return
            }
            
            Task { @MainActor in
                guard let ownPrivateKey = AppState.shared.tempPrivateKey else { return }
                if let sessionKey = try? E2EEncryption.deriveSessionKey(ownPrivateKey: ownPrivateKey, peerPublicKey: peerPubKey) {
                    let session = EncryptedSession(deviceId: deviceId, sessionKey: sessionKey)
                    connection.setEncryptedSession(session)
                    AppState.shared.isConnected = true
                    AppState.shared.connectedDeviceId = deviceId
                    AppState.shared.connectionQuality = .excellent
                    AppState.shared.pairingState = .connected
                    AppState.shared.pairingCompleted()
                    
                    let peerDevice = PeerDevice(
                        id: deviceId,
                        name: AppState.shared.activeConnectedDevice?.name ?? "Android Device",
                        model: AppState.shared.activeConnectedDevice?.model ?? "Android",
                        osVersion: AppState.shared.activeConnectedDevice?.osVersion ?? "Android",
                        protocolVersion: 1,
                        capabilities: []
                    )
                    ConnectionStateManager.shared.transition(to: .connected, device: peerDevice)
                }
            }
        }
        
        if type != "PAIRING_INIT" && type != "PAIRING_REQUEST" && type != "KEY_EXCHANGE" {
            if let router = AppState.shared.messageRouter {
                let deviceId = connection.deviceId ?? connection.id
                await router.route(rawData: data, from: deviceId)
            }
        }
    }
    
    // MARK: - Pairing Protocol Handshake Operations
    
    func sendPairingApproved(to connection: WebSocketConnection, deviceId: String? = nil, macName: String, publicKey: String) async {
        guard connections[connection.id] != nil && connection.channel.isActive else {
            logger.error("[WebSocket] Cannot send PAIRING_APPROVED, connection is inactive or unregistered", category: .security)
            return
        }
        let sessionId = AppState.shared.activeSession?.id ?? "NONE"
        let deviceId = connection.deviceId ?? connection.id
        logger.info("[SESSION #\(sessionId)] [STAGE 9] ENTER sendPairingApproved to device \(deviceId)", category: .security)
        let payload: [String: String] = [
            "type": "PAIRING_APPROVED",
            "macName": macName,
            "publicKey": publicKey,
            "sessionToken": UUID().uuidString
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            logger.info("[SESSION #\(sessionId)] [STAGE 9] PAIRING_APPROVED JSON encoded (len: \(data.count)). Invoking send...", category: .security)
            try await connection.send(data)
            logger.info("[SESSION #\(sessionId)] [STAGE 9] EXIT sendPairingApproved (send completed successfully)", category: .security)
        } catch {
            logger.error("[SESSION #\(sessionId)] [STAGE 9] ERROR in sendPairingApproved: \(error.localizedDescription)", category: .security, error: error)
        }
    }
    
    func sendPairingPinDisplayed(to connection: WebSocketConnection) async {
        let payload: [String: String] = [
            "type": "PAIRING_PIN_DISPLAYED"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? await connection.send(data)
        }
    }
    
    func sendPairingQrDisplayed(to connection: WebSocketConnection) async {
        let payload: [String: String] = [
            "type": "PAIRING_QR_DISPLAYED"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? await connection.send(data)
        }
    }
    
    func sendPairingRejected(to connection: WebSocketConnection) async {
        let payload: [String: String] = [
            "type": "PAIRING_REJECTED",
            "reason": "User rejected connection request"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? await connection.send(data)
        }
        connection.close()
    }
    
    func send(_ data: Data, to deviceId: String) async throws {
        guard let connection = connections.values.first(where: { $0.deviceId == deviceId || $0.id == deviceId }) else {
            throw WebSocketError.deviceNotConnected(deviceId)
        }
        try await connection.send(data)
    }
    
    func broadcast(_ data: Data) async {
        for (_, connection) in connections {
            try? await connection.send(data)
        }
    }
    
    var connectedDeviceIds: [String] {
        Array(connections.keys)
    }
    
    private func startScreenCapture(on connection: WebSocketConnection) {
        if self.activeCaptureService != nil {
            LinkOSLogger.shared.info("[RemoteDesktop] Screen capture already active. Skipping duplicate initialization.", category: .media)
            return
        }
        LinkOSLogger.shared.info("[RemoteDesktop] Capture started", category: .media)
        let service = ScreenCaptureService()
        self.activeCaptureService = service
        
        let lock = NSLock()
        var isSendingFrame = false
        var isFirstFrame = true
        
        Task {
            await service.startCapture(fps: 30) { sampleBuffer in
                if isFirstFrame {
                    isFirstFrame = false
                    LinkOSLogger.shared.info("[RemoteDesktop] First frame captured", category: .media)
                }
                
                // Backpressure: drop frame if the previous one is still transmitting to prevent latency queue backlog
                lock.lock()
                if isSendingFrame {
                    lock.unlock()
                    return
                }
                isSendingFrame = true
                lock.unlock()
                
                let quality = service.currentPreset.compressionQuality
                if let jpegData = ScreenCaptureService.sampleBufferToJPEG(sampleBuffer, compressionQuality: quality) {
                    Task {
                        do {
                            try await connection.send(jpegData)
                        } catch {
                            LinkOSLogger.shared.error("[RemoteDesktop] ERROR: Failed to send frame: \(error.localizedDescription)", category: .media)
                        }
                        lock.lock()
                        isSendingFrame = false
                        lock.unlock()
                    }
                } else {
                    lock.lock()
                    isSendingFrame = false
                    lock.unlock()
                }
            }
        }
    }
}

// MARK: - WebSocket Connection

/// Represents a single WebSocket connection to a peer device.
final class WebSocketConnection {
    let id: String
    let channel: Channel
    let isInput: Bool
    private(set) var deviceId: String?
    private(set) var encryptedSession: EncryptedSession?
    
    var onMessage: ((Data) async -> Void)?
    var onClose: (() -> Void)?
    
    init(id: String = UUID().uuidString, channel: Channel, isInput: Bool = false) {
        self.id = id
        self.channel = channel
        self.isInput = isInput
    }
    
    func setDeviceId(_ deviceId: String) {
        self.deviceId = deviceId
    }
    
    func setEncryptedSession(_ session: EncryptedSession) {
        self.encryptedSession = session
    }
    
    func send(_ data: Data) async throws {
        let payload: Data
        let opcode: WebSocketOpcode
        if let session = encryptedSession {
            payload = try session.encrypt(data)
            opcode = .binary
        } else {
            payload = data
            opcode = .text
        }
        
        var buffer = channel.allocator.buffer(capacity: payload.count)
        buffer.writeBytes(payload)
        let frame = WebSocketFrame(fin: true, opcode: opcode, data: buffer)
        try await channel.writeAndFlush(frame)
    }
    
    func receive(_ data: Data) async {
        let sessionId = await AppState.shared.activeSession?.id ?? "NONE"
        let plaintext: Data
        if let session = encryptedSession {
            guard let decrypted = try? session.decrypt(data) else {
                return
            }
            plaintext = decrypted
        } else {
            plaintext = data
        }
        
        await onMessage?(plaintext)
    }
    
    func close() {
        channel.close(promise: nil)
        onClose?()
    }
}

// MARK: - NIO Channel Handlers

private final class LinkOSWebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    
    private weak var server: WebSocketServer?
    private var connection: WebSocketConnection?
    var isInputChannel: Bool = false
    
    init(server: WebSocketServer) {
        self.server = server
    }
    
    func handlerAdded(context: ChannelHandlerContext) {
        setupConnection(context: context)
    }
    
    func channelActive(context: ChannelHandlerContext) {
        setupConnection(context: context)
    }
    
    private func setupConnection(context: ChannelHandlerContext) {
        guard self.connection == nil else { return }
        let conn = WebSocketConnection(channel: context.channel, isInput: self.isInputChannel)
        conn.onMessage = { [weak self] data in
            guard let self = self, let server = self.server else { return }
            
            // Fast path for raw JPEG mirroring display frames from Android
            if data.count > 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF {
                if let mirroringPlugin = await AppState.shared.pluginManager?.getPlugin(PhoneMirroringPlugin.self) {
                    await mirroringPlugin.handleRawStreamFrame(data)
                }
                return
            }
            
            // Fast path for raw system audio frames from Android
            if data.count > 0 && data[0] == 0xAA {
                await PhoneAudioService.shared.receiveAudioPacket(data)
                return
            }
            
            await server.handleIncomingData(data, from: conn)
        }
        conn.onClose = { [weak self] in
            guard let self = self, let server = self.server else { return }
            Task { @MainActor in
                server.removeConnection(conn.id)
            }
        }
        self.connection = conn
        Task { @MainActor in
            server?.addConnection(conn)
        }
    }
    
    func channelInactive(context: ChannelHandlerContext) {
        if let conn = connection {
            Task { @MainActor in
                server?.removeConnection(conn.id)
            }
        }
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        let isMaskedBefore = frame.maskKey != nil
        if let maskKey = frame.maskKey {
            frame.data.webSocketUnmask(maskKey)
            frame.maskKey = nil
        }
        
        LinkOSLogger.shared.info("[RAW FRAME RECEIVED] opcode=\(frame.opcode) length=\(frame.data.readableBytes) masked=\(isMaskedBefore)", category: .network)
        
        switch frame.opcode {
        case .text, .binary:
            var dataBuffer = frame.data
            guard let bytes = dataBuffer.readBytes(length: dataBuffer.readableBytes) else { return }
            let data = Data(bytes)
            #if DEBUG_PAIRING
            let str = String(data: data, encoding: .utf8) ?? "NON-UTF8"
            LinkOSLogger.shared.info("[RAW FRAME PAYLOAD UNMASKED] \(str)", category: .network)
            #endif
            
            if connection == nil {
                setupConnection(context: context)
            }
            
            if self.isInputChannel {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    GestureInterpreter.shared.interpret(json: json)
                    return
                }
            }
            
            // Prioritize cursor and input packets on the NIO EventLoop thread directly to minimize latency
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var effectiveJson = json
                if let payloadStr = json["payload"] as? String,
                   let payloadData = payloadStr.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] {
                    effectiveJson = nested
                } else if let nested = json["payload"] as? [String: Any] {
                    effectiveJson = nested
                }
                
                let action = json["action"] as? String ?? effectiveJson["action"] as? String
                if action == "move" || action == "click" || action == "scroll" {
                    GestureInterpreter.shared.interpret(json: effectiveJson)
                    return
                }
            }
            
            if let conn = connection {
                Task {
                    await conn.receive(data)
                }
            } else {
                LinkOSLogger.shared.error("[TRANSPORT] CRITICAL FAILURE: connection object is nil in channelRead!", category: .network)
            }
            
        case .connectionClose:
            LinkOSLogger.shared.info("[RAW FRAME RECEIVED] Connection close frame received", category: .network)
            context.close(promise: nil)
            
        case .ping:
            LinkOSLogger.shared.info("[RAW FRAME RECEIVED] Ping frame received", category: .network)
            var dataBuffer = frame.data
            let pongFrame = WebSocketFrame(fin: true, opcode: .pong, data: dataBuffer)
            context.writeAndFlush(wrapOutboundOut(pongFrame), promise: nil)
            
        default:
            break
        }
    }
}

final class HTTPByteBufferResponsePartHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }
}

enum WebSocketError: Error, LocalizedError {
    case deviceNotConnected(String)
    
    var errorDescription: String? {
        switch self {
        case .deviceNotConnected(let id): return "Device not connected: \(id)"
        }
    }
}
