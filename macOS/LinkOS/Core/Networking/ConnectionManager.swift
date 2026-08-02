import Foundation

/// Central connection manager coordinating Bonjour, WebSocket, and encrypted sessions.
/// Acts as the single point of coordination between networking and the rest of the app.
actor ConnectionManager {
    
    private let webSocketServer: WebSocketServer
    private var sessions: [String: EncryptedSession] = [:]  // deviceId -> session
    private let logger = LinkOSLogger.shared
    
    // Callbacks for higher-level components
    var onDeviceConnected: ((String) async -> Void)?
    var onDeviceDisconnected: ((String) async -> Void)?
    var onMessageReceived: ((String, Data) async -> Void)?
    
    init(server: WebSocketServer = .shared) {
        self.webSocketServer = server
    }
    
    // MARK: - Server Lifecycle
    
    func startServer() async {
        do {
            try await webSocketServer.start()
            logger.info("Connection manager started", category: .network)
        } catch {
            logger.error("Failed to start connection manager", category: .network, error: error)
        }
    }
    
    func stopServer() async {
        await webSocketServer.stop()
        sessions.removeAll()
        logger.info("Connection manager stopped", category: .network)
    }
    
    // MARK: - Session Management
    
    /// Register an encrypted session after successful pairing.
    func registerSession(_ session: EncryptedSession) {
        sessions[session.deviceId] = session
        logger.info("Session registered for device: \(session.deviceId)", category: .security)
    }
    
    /// Remove a device's session.
    func removeSession(deviceId: String) {
        sessions.removeValue(forKey: deviceId)
    }
    
    /// Get the encrypted session for a device.
    func session(for deviceId: String) -> EncryptedSession? {
        sessions[deviceId]
    }
    
    // MARK: - Messaging
    
    /// Send a message to a specific device.
    func send(_ data: Data, to deviceId: String) async throws {
        try await webSocketServer.send(data, to: deviceId)
    }
    
    /// Broadcast a message to all connected devices.
    func broadcast(_ data: Data) async {
        await webSocketServer.broadcast(data)
    }
    
    /// Disconnect all devices.
    func disconnectAll() async {
        await stopServer()
    }
    
    /// Disconnect all active connections.
    func disconnectAllConnections() async {
        await webSocketServer.disconnectAllConnections()
    }
    
    // MARK: - Status
    
    var connectedDeviceIds: [String] {
        get async {
            await webSocketServer.connectedDeviceIds
        }
    }
    
    var isRunning: Bool {
        get async {
            await webSocketServer.connectedDeviceIds.count >= 0  // Server exists
        }
    }
}
