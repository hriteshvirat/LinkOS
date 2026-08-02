import Foundation
import AppKit

/// Retrieves list of installed applications on macOS and launches them remotely from Android.
@MainActor
final class AppLauncherService: NSObject, ConnectionStateSubscriber {
    static let shared = AppLauncherService()
    
    var subscriberId = "app_launcher_service"
    private let logger = LinkOSLogger.shared
    
    private override init() {
        super.init()
        ConnectionStateManager.shared.subscribe(self)
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        // Handle connections
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .session else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let action = json["action"] as? String {
                
                if action == "query_apps" {
                    await broadcastApplicationsList(to: deviceId)
                } else if action == "launch_app", let appName = json["app_name"] as? String {
                    launchApplication(name: appName)
                }
            }
        } catch {
            logger.error("Failed to parse app launcher payload: \(error.localizedDescription)", category: .plugin)
        }
    }
    
    func qosDidChange(state: QoSState) async {
        // QoS updates
    }
    
    private func launchApplication(name: String) {
        let ws = NSWorkspace.shared
        
        // Map common app queries to absolute paths or bundle identifiers
        var appPath = ""
        switch name.lowercased() {
        case "finder":
            appPath = "/System/Library/CoreServices/Finder.app"
        case "safari":
            appPath = "/Applications/Safari.app"
        case "vscode", "visual studio code":
            appPath = "/Applications/Visual Studio Code.app"
        case "xcode":
            appPath = "/Applications/Xcode.app"
        case "terminal":
            appPath = "/System/Applications/Utilities/Terminal.app"
        default:
            // Query Applications folder
            let fm = FileManager.default
            let appDirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities"]
            for dir in appDirs {
                let path = "\(dir)/\(name).app"
                if fm.fileExists(atPath: path) {
                    appPath = path
                    break
                }
            }
        }
        
        guard !appPath.isEmpty else {
            logger.warning("Could not locate application path for: \(name)", category: .plugin)
            return
        }
        
        let url = URL(fileURLWithPath: appPath)
        let config = NSWorkspace.OpenConfiguration()
        ws.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error = error {
                self?.logger.error("Failed to launch application \(name): \(error.localizedDescription)", category: .plugin)
            } else {
                self?.logger.info("Launched app successfully: \(name)", category: .plugin)
            }
        }
    }
    
    private func broadcastApplicationsList(to deviceId: String) async {
        let appDirs = ["/Applications", "/System/Applications"]
        let fm = FileManager.default
        var appList: [String] = ["Finder", "Safari", "Terminal", "VSCode", "Xcode"]
        
        for dir in appDirs {
            if let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in urls where url.pathExtension == "app" {
                    let name = url.deletingPathExtension().lastPathComponent
                    if !appList.contains(name) {
                        appList.append(name)
                    }
                }
            }
        }
        
        let payload: [String: Any] = [
            "action": "apps_list",
            "apps": appList
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .session, payload: data, from: DeviceIdentity.deviceId)
        }
    }
}
