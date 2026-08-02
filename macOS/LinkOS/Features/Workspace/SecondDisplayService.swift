import Foundation
import CoreGraphics

enum SecondDisplayMode: String, Codable {
    case extend = "Extend Desktop"
    case mirror = "Mirror Primary"
    case reference = "Reference Screen"
}

final class SecondDisplayService {
    private(set) var currentMode: SecondDisplayMode = .extend
    private(set) var isSecondDisplayActive = false
    
    func enableSecondDisplay(mode: SecondDisplayMode = .extend, resolutionWidth: Int = 2560, resolutionHeight: Int = 1600) {
        self.currentMode = mode
        self.isSecondDisplayActive = true
        LinkOSLogger.shared.info("Enabled Wireless Second Display (\(mode.rawValue)) at \(resolutionWidth)x\(resolutionHeight)", category: .media)
    }
    
    func disableSecondDisplay() {
        self.isSecondDisplayActive = false
        LinkOSLogger.shared.info("Disabled Wireless Second Display", category: .media)
    }
}

final class TabletPlugin: LinkOSPlugin {
    let pluginId = "tablet"
    let displayName = "Tablet Mode & Stylus"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["tablet"]
    let requiredPermissions: Set<String> = ["SCREEN_VIEW", "MOUSE_INPUT"]
    
    private(set) var isActive = false
    private let secondDisplayService = SecondDisplayService()
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("TabletPlugin activated", category: .media)
    }
    
    func deactivate() async {
        isActive = false
        secondDisplayService.disableSecondDisplay()
        LinkOSLogger.shared.info("TabletPlugin deactivated", category: .media)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
              let action = json["action"] as? String else { return }
        
        if action == "stylus_input" {
            // Receive stylus pressure & tilt from Android tablet
            let pressure = json["pressure"] as? Double ?? 1.0
            let tiltX = json["tiltX"] as? Double ?? 0.0
            LinkOSLogger.shared.debug("Received tablet stylus stroke (pressure: \(pressure), tilt: \(tiltX))", category: .input)
        }
    }
}
