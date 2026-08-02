import Foundation
import CoreGraphics
import ApplicationServices

/// Parses incoming gesture packets and routes them to InputInjectionService.
final class GestureInterpreter {
    static let shared = GestureInterpreter()
    private let injector = InputInjectionService.shared
    
    private func extractDouble(_ val: Any?) -> Double? {
        if let d = val as? Double { return d }
        if let i = val as? Int { return Double(i) }
        if let n = val as? NSNumber { return n.doubleValue }
        if let s = val as? String { return Double(s) }
        return nil
    }
    
    private func extractInt32(_ val: Any?) -> Int32? {
        if let i = val as? Int32 { return i }
        if let i = val as? Int { return Int32(i) }
        if let d = val as? Double { return Int32(d) }
        if let n = val as? NSNumber { return n.int32Value }
        return nil
    }

    func interpret(json: [String: Any]) {
        guard let action = json["action"] as? String else { return }
        
        // Defer Accessibility prompt until first use of Trackpad/Keyboard input
        if !AXIsProcessTrusted() {
            DispatchQueue.main.async {
                PermissionManager.shared.requestPermissionExplicitly(.accessibility)
            }
            return
        }
        
        switch action {
        case "move":
            if let dx = extractDouble(json["dx"]), let dy = extractDouble(json["dy"]) {
                injector.moveCursor(deltaX: dx, deltaY: dy)
            } else {
                LinkOSLogger.shared.error("[INPUT] Failed to parse dx/dy from move payload: \(json)", category: .input)
            }
        case "drag_start":
            if UserDefaults.standard.object(forKey: "linkos_trackpad_three_finger_drag") as? Bool ?? true {
                LinkOSLogger.shared.info("[INPUT] drag_start action", category: .input)
                injector.dragStart()
            }
        case "drag_end":
            if UserDefaults.standard.object(forKey: "linkos_trackpad_three_finger_drag") as? Bool ?? true {
                LinkOSLogger.shared.info("[INPUT] drag_end action", category: .input)
                injector.dragEnd()
            }
        case "click":
            let buttonRaw = json["button"] as? String ?? "left"
            let isTap = json["isTap"] as? Bool ?? false
            
            if isTap {
                if buttonRaw == "left" && !(UserDefaults.standard.object(forKey: "linkos_trackpad_tap_to_click") as? Bool ?? true) {
                    return
                }
                if buttonRaw == "right" && !(UserDefaults.standard.object(forKey: "linkos_trackpad_two_finger_secondary_click") as? Bool ?? true) {
                    return
                }
            }
            
            let button: CGMouseButton = (buttonRaw == "right") ? .right : (buttonRaw == "middle" ? .center : .left)
            LinkOSLogger.shared.info("[INPUT] click action button=\(buttonRaw) isTap=\(isTap)", category: .input)
            injector.click(button: button)
        case "scroll":
            if let dx = extractDouble(json["dx"]), let dy = extractDouble(json["dy"]) {
                injector.scroll(deltaX: dx, deltaY: dy)
            }
        case "mission_control":
            injector.triggerMissionControl()
        case "app_expose":
            injector.triggerAppExpose()
        case "spaces_left":
            injector.triggerSpacesLeft()
        case "spaces_right":
            injector.triggerSpacesRight()
        case "launchpad":
            injector.triggerLaunchpad()
        case "zoom":
            let isZoomEnabled = UserDefaults.standard.object(forKey: "linkos_trackpad_five_finger_zoom") as? Bool ?? true
            if isZoomEnabled {
                if let scale = extractDouble(json["scale"]) {
                    injector.zoom(scale: scale)
                }
            }
        case "media":
            if let key = json["key"] as? String {
                injector.triggerMediaKey(key)
            }
        case "keyboard":
            if let text = json["text"] as? String {
                injector.typeText(text)
            } else if let key = json["key"] as? String {
                injector.pressSpecialKey(key)
            }
        default:
            break
        }
    }
}

final class TrackpadPlugin: LinkOSPlugin {
    let pluginId = "input"
    let displayName = "Magic Trackpad"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["input", "trackpad"]
    let requiredPermissions: Set<String> = ["MOUSE_INPUT", "KEYBOARD_INPUT"]
    
    private(set) var isActive = false
    private let interpreter = GestureInterpreter()
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("TrackpadPlugin activated", category: .input)
    }
    
    func deactivate() async {
        isActive = false
        LinkOSLogger.shared.info("TrackpadPlugin deactivated", category: .input)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] else { return }
        interpreter.interpret(json: json)
    }
}
