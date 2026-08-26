import Foundation
import AppKit

/// Simulates system-wide media operations on macOS (Play/Pause, volume, track control).
@MainActor
final class MediaControlService: NSObject, ConnectionStateSubscriber {
    static let shared = MediaControlService()
    
    var subscriberId = "media_control_service"
    private let logger = LinkOSLogger.shared
    
    private override init() {
        super.init()
        ConnectionStateManager.shared.subscribe(self)
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        // Handle connections
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .mediaControl else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let action = json["action"] as? String {
                
                logger.info("Executing remote media control: \(action)", category: .protocol_)
                executeMediaAction(action, extra: json["value"] as? Int)
            }
        } catch {
            logger.error("Failed to parse media control payload: \(error.localizedDescription)", category: .protocol_)
        }
    }
    
    func qosDidChange(state: QoSState) async {
        // QoS updates
    }
    
    private func executeMediaAction(_ action: String, extra: Int?) {
        var scriptSource = ""
        switch action {
        case "play_pause":
            scriptSource = """
            tell application "System Events"
                key code 16 -- Play/Pause keycode in macOS
            end tell
            """
            // Backup fallback for Spotify and Apple Music if global keycode is sandboxed
            if !runAppleScript(scriptSource) {
                _ = runAppleScript("tell application \"Spotify\" to playpause")
                _ = runAppleScript("tell application \"Music\" to playpause")
            }
        case "next":
            scriptSource = "tell application \"System Events\" to key code 19"
            if !runAppleScript(scriptSource) {
                _ = runAppleScript("tell application \"Spotify\" to next track")
                _ = runAppleScript("tell application \"Music\" to next track")
            }
        case "previous":
            scriptSource = "tell application \"System Events\" to key code 18"
            if !runAppleScript(scriptSource) {
                _ = runAppleScript("tell application \"Spotify\" to previous track")
                _ = runAppleScript("tell application \"Music\" to previous track")
            }
        case "volume_up":
            _ = runAppleScript("set volume output volume ((output volume of (get volume settings)) + 6)")
        case "volume_down":
            _ = runAppleScript("set volume output volume ((output volume of (get volume settings)) - 6)")
        case "mute":
            _ = runAppleScript("set volume with output muted")
        case "unmute":
            _ = runAppleScript("set volume without output muted")
        default:
            break
        }
    }
    
    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
    
    @discardableResult
    static func runAppleScriptGetString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
    
    static func getSystemVolume() -> Double {
        if let valStr = runAppleScriptGetString("output volume of (get volume settings)"),
           let val = Double(valStr) {
            return val / 100.0
        }
        return 0.5
    }
    
    static func setSystemVolume(_ volume: Double) {
        let volInt = Int(volume * 100.0)
        _ = runAppleScriptGetString("set volume output volume \(volInt)")
    }
}

