import Foundation

/// Manages incoming call alerts and phone interface status mirrored from Android peer.
@MainActor
final class PhoneIntegrationService: NSObject, ConnectionStateSubscriber {
    static let shared = PhoneIntegrationService()
    
    var subscriberId = "phone_integration_service"
    
    // Callback when call state changes
    var onCallStateChanged: ((String, String) -> Void)?
    
    private var activeCallState = "IDLE"
    private var callerNumber = ""
    private let logger = LinkOSLogger.shared
    
    private override init() {
        super.init()
        ConnectionStateManager.shared.subscribe(self)
    }
    
    func onConnectionPhaseChanged(phase: ConnectionPhase, device: PeerDevice?) {
        if phase == .disconnected {
            activeCallState = "IDLE"
            callerNumber = ""
        }
    }
    
    func onMessageReceived(channel: MessageChannel, payload: Data, fromDeviceId: String) {
        guard channel == .phone else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let action = json["action"] as? String {
                
                if action == "call_state",
                   let state = json["state"] as? String,
                   let number = json["number"] as? String {
                    
                    self.activeCallState = state
                    self.callerNumber = number
                    
                    self.onCallStateChanged?(state, number)
                    logger.info("Call state transition: \(state) for \(number)", category: .notifications)
                }
            }
        } catch {
            logger.error("Failed to parse telephony payload: \(error.localizedDescription)", category: .notifications)
        }
    }
    
    func onQoSChanged(state: QoSState) {
        // QoS updates
    }
    
    // Outbound Telephony Command Controllers
    
    func acceptCall() async {
        let payload: [String: Any] = [
            "action": "accept"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .phone, payload: data, from: DeviceIdentity.deviceId)
        }
    }
    
    func rejectCall() async {
        let payload: [String: Any] = [
            "action": "reject"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .phone, payload: data, from: DeviceIdentity.deviceId)
        }
    }
    
    func toggleMute(muted: Bool) async {
        let payload: [String: Any] = [
            "action": "mute",
            "enabled": muted
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .phone, payload: data, from: DeviceIdentity.deviceId)
        }
    }
    
    func toggleSpeaker(enabled: Bool) async {
        let payload: [String: Any] = [
            "action": "speaker",
            "enabled": enabled
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .phone, payload: data, from: DeviceIdentity.deviceId)
        }
    }
}
