import Foundation
import Combine

@MainActor
final class PhoneMirroringPlugin: LinkOSPlugin, ConnectionStateSubscriber {
    let pluginId = "phone_mirroring"
    let displayName = "Phone Mirroring"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["phone"]
    let requiredPermissions: Set<String> = ["SCREEN_VIEW", "SCREEN_CONTROL"]
    
    var subscriberId: String { "phone_mirroring_plugin" }
    var isActive = false
    private let logger = LinkOSLogger.shared
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
        // Subscribe to connection events
        ConnectionStateManager.shared.subscribe(self)
    }
    
    func activate() async throws {
        isActive = true
        logger.info("PhoneMirroringPlugin activated", category: .plugin)
    }
    
    func deactivate() async {
        isActive = false
        logger.info("PhoneMirroringPlugin deactivated", category: .plugin)
    }
    
    // MARK: - ConnectionStateSubscriber Conformance
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        if phase == .disconnected {
            // Stop phone mirroring session when disconnected
            await PhoneSession.shared.stopSession()
        }
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .phone else { return }
        
        // Handle incoming control messages (e.g. status updates)
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let action = json["action"] as? String {
            if action == "status_update" {
                if let battery = json["battery"] as? Int {
                    PhoneSession.shared.batteryLevel = battery
                }
                if let latency = json["latency"] as? Double {
                    PhoneSession.shared.latencyMs = latency
                }
            }
        }
    }
    
    func handleRawStreamFrame(_ data: Data) async {
        guard isActive else { return }
        PhoneSession.shared.receiveFrame(data)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        if message.channel == "phone" {
            await didReceiveMessage(channel: .phone, payload: message.payload, from: message.deviceId)
        }
    }
}
