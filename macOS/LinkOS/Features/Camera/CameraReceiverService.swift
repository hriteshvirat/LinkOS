import Foundation
import AppKit

/// Receives camera frames streamed from Android peer client and feeds the local preview.
/// Also hooks up virtual CoreMediaIO camera extensions if configured.
@MainActor
final class CameraReceiverService: NSObject, ConnectionStateSubscriber {
    static let shared = CameraReceiverService()
    
    var subscriberId = "camera_receiver_service"
    
    // Callback when a new preview frame is received, containing frame image, flash active state, and lens facing name
    var onFrameReceived: ((NSImage, Bool, String) -> Void)?
    
    private var isFlashActive = false
    private var currentLens = "rear"
    private let logger = LinkOSLogger.shared
    
    private var activeSessionId = String(UUID().uuidString.prefix(8))
    private var frameCount = 0
    
    private override init() {
        super.init()
        ConnectionStateManager.shared.subscribe(self)
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        if phase == .disconnected {
            logger.info("Camera stream source disconnected", category: .media)
            activeSessionId = String(UUID().uuidString.prefix(8))
            frameCount = 0
        }
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .camera else { return }
        
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let action = json["action"] as? String, action == "capture_image" {
            NotificationCenter.default.post(name: NSNotification.Name("CameraContinuityCaptureRequested"), object: nil)
            return
        }
        
        frameCount += 1
        let shouldLog = frameCount % 30 == 1
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        
        if shouldLog {
            logger.info("[CameraReceiver] [\(timestamp)] [\(activeSessionId)] Stage: Received - Payload size \(payload.count) bytes from \(deviceId)", category: .media)
        }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let base64Image = json["image"] as? String {
                
                let decodeStart = Date()
                if let imageData = Data(base64Encoded: base64Image),
                   let image = NSImage(data: imageData) {
                    
                    let decodeDuration = Int(Date().timeIntervalSince1970 * 1000) - Int(decodeStart.timeIntervalSince1970 * 1000)
                    if shouldLog {
                        logger.info("[CameraReceiver] [\(timestamp)] [\(activeSessionId)] Stage: Decoded - NSImage size: \(image.size) in \(decodeDuration)ms", category: .media)
                    }
                    
                    self.isFlashActive = json["flash_active"] as? Bool ?? false
                    self.currentLens = json["lens_facing"] as? String ?? "rear"
                    
                    // Propagate to UI preview callback
                    self.onFrameReceived?(image, self.isFlashActive, self.currentLens)
                    if shouldLog {
                        logger.info("[CameraReceiver] [\(Int(Date().timeIntervalSince1970 * 1000))] [\(activeSessionId)] Stage: Rendered - Frame sent to SwiftUI views", category: .media)
                    }
                } else {
                    logger.error("Failed to decode NSImage from payload data", category: .media)
                }
            }
        } catch {
            logger.error("Failed to parse camera frame payload: \(error.localizedDescription)", category: .media)
        }
    }
    
    func qosDidChange(state: QoSState) async {
        // Log QoS adjustments for camera sync
    }
    
    func sendToggleFlashCommand(enabled: Bool) async {
        let payload: [String: Any] = [
            "action": "toggle_flash",
            "enabled": enabled
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let msg = MessageRouter.createEvent(channel: "camera", payload: data)
            await AppState.shared.connectionManager?.broadcast(msg)
        }
    }
    
    func sendSwitchLensCommand() async {
        let payload: [String: Any] = [
            "action": "switch_lens"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let msg = MessageRouter.createEvent(channel: "camera", payload: data)
            await AppState.shared.connectionManager?.broadcast(msg)
        }
    }
    
    func sendZoomCommand(ratio: Float) async {
        let payload: [String: Any] = [
            "action": "zoom",
            "ratio": ratio
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let msg = MessageRouter.createEvent(channel: "camera", payload: data)
            await AppState.shared.connectionManager?.broadcast(msg)
        }
    }
}
