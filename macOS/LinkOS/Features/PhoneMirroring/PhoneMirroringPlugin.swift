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
            PhoneSessionManager.shared.activeSession.setReconnecting()
        } else if phase == .connected {
            // Suppress automatic reconnect if the user explicitly stopped mirroring.
            // userStoppedMirroring is reset to false only when the user opens the mirror window again.
            guard !PhoneSessionManager.shared.userStoppedMirroring else {
                LinkOSLogger.shared.info("[PhoneMirroringPlugin] connectionDidChange(.connected) suppressed — userStoppedMirroring is true.", category: .media)
                return
            }
            PhoneSessionManager.shared.activeSession.setConnected(source: "connectionDidChange")
        }
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .phone else { return }
        
        // Handle incoming control messages (e.g. status updates)
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let action = json["action"] as? String {
            let activeSession = PhoneSessionManager.shared.activeSession
            if action == "status_update" {
                if let battery = json["battery"] as? Int {
                    activeSession.batteryLevel = battery
                }
                if let latency = json["latency"] as? Double {
                    activeSession.latencyMs = latency
                }
            } else if action == "diagnostic_status" {
                if let stage = json["stage"] as? String,
                   let ok = json["ok"] as? Bool {
                    let sessionId = json["session_id"] as? String ?? ""
                    let error = json["error"] as? String ?? ""
                    if let gen = json["session_generation"] as? Int {
                        activeSession.expectedSessionGeneration = UInt8(gen & 0xFF)
                    }
                    if stage == "privacy_dismissed_by_user" {
                        Task { @MainActor in
                            PhoneSessionManager.shared.activeSession.isPrivacyModeEnabled = false
                            PhoneSessionManager.shared.activeSession.isPaused = true // Pause Mac remote input
                        }
                    }
                    activeSession.updateDiagnostic(stage: stage, ok: ok, error: error)
                }
            } else if action == "call_state" {
                if let state = json["state"] as? String {
                    activeSession.callState = state
                    activeSession.incomingCallNumber = json["number"] as? String ?? ""
                    
                    if state == "RINGING" {
                        Task { @MainActor in
                            // Use showMirrorForIncomingCall (NOT showMirror) to preserve userStoppedMirroring.
                            // An incoming phone call should not override the user's deliberate disconnect decision.
                            PhoneWindowController.showMirrorForIncomingCall()
                        }
                    }
                }
            } else if action == "FOREGROUND_APP" {
                if let pkg = json["package"] as? String, let category = json["category"] as? String {
                    Task { @MainActor in
                        PhoneSessionManager.shared.activeSession.activeAppCategory = category
                        PhoneSessionManager.shared.activeSession.activeAppPackage = pkg
                    }
                }
            } else if action == "ROTATION_STARTED" {
                // Android sent the new rotation angle. Set it immediately so the Metal
                // renderer applies CIImage.oriented() on the very next decoded frame.
                let angle = json["angle"] as? Int ?? 0
                Task { @MainActor in
                    PhoneSessionManager.shared.activeSession.displayRotation = angle
                    PhoneSessionManager.shared.activeSession.isRotating = true
                    LinkOSLogger.shared.info("[PhoneMirroringPlugin] ROTATION_STARTED: displayRotation set to \(angle)°", category: .media)
                }
            } else if action == "ROTATION_COMPLETE" {
                let w = json["width"] as? Int ?? 0
                let h = json["height"] as? Int ?? 0
                let angle = json["angle"] as? Int ?? 0
                Task { @MainActor in
                    let session = PhoneSessionManager.shared.activeSession
                    session.displayRotation = angle
                    session.isRotating = false
                    if w > 0 && h > 0 {
                        // Animate the window to the rotated aspect ratio.
                        // w/h are already the rotated dimensions (landscape: w > h).
                        LinkOSLogger.shared.info("[PhoneMirroringPlugin] ROTATION_COMPLETE: animating window to \(w)x\(h) at \(angle)°", category: .media)
                        PhoneWindowController.shared.animateAspectRatioChange(CGSize(width: CGFloat(w), height: CGFloat(h)))
                    }
                }
            }
        }
    }
    
    func handleRawStreamFrame(_ data: Data) async {
        guard isActive else { return }
        PhoneSessionManager.shared.activeSession.receiveFrame(data)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        if message.channel == "phone" {
            await didReceiveMessage(channel: .phone, payload: message.payload, from: message.deviceId)
        }
    }
}
