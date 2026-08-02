import Foundation
import AppKit

/// Retrieves and synchronizes current activity context (like browser tabs) between macOS and Android.
@MainActor
final class HandoffService: NSObject, ConnectionStateSubscriber {
    static let shared = HandoffService()
    
    var subscriberId = "handoff_service"
    private let logger = LinkOSLogger.shared
    
    private override init() {
        super.init()
        ConnectionStateManager.shared.subscribe(self)
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        // Handle connections
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .handoff else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let urlString = json["url"] as? String,
               let url = URL(string: urlString) {
                // Open incoming handoff URL on Mac natively
                NSWorkspace.shared.open(url)
                logger.info("Opened incoming handoff URL: \(urlString)", category: .protocol_)
            }
        } catch {
            logger.error("Failed to parse incoming handoff message: \(error.localizedDescription)", category: .protocol_)
        }
    }
    
    func qosDidChange(state: QoSState) async {
        // QoS updates
    }
    
    /// Pulls current browser tab URL via AppleScript and broadcasts it to Android.
    func triggerHandoffToAndroid() async {
        guard let url = getCurrentBrowserTabURL() else { return }
        let payload: [String: Any] = [
            "url": url
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .handoff, payload: data, from: DeviceIdentity.deviceId)
            logger.info("Broadcasted handoff URL to Android: \(url)", category: .protocol_)
        }
    }
    
    private func getCurrentBrowserTabURL() -> String? {
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        
        var scriptString = ""
        if frontmostApp.contains("com.apple.Safari") {
            scriptString = "tell application \"Safari\" to return URL of front document"
        } else if frontmostApp.contains("com.google.Chrome") {
            scriptString = "tell application \"Google Chrome\" to return URL of active tab of front window"
        } else {
            return nil
        }
        
        guard let appleScript = NSAppleScript(source: scriptString) else { return nil }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        
        if error != nil {
            return nil
        }
        return result.stringValue
    }
}
