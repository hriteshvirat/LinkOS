import Foundation
import AppKit
import UserNotifications

final class CommandExecutor {
    
    func execute(action: AIActionPayload) async -> (Bool, String) {
        if let target = action.parameters["target"], target == "phone" {
            let correlationId = UUID().uuidString
            var newParams = action.parameters
            newParams["correlation_id"] = correlationId
            let mutableAction = AIActionPayload(actionType: action.actionType, parameters: newParams)
            if let payloadData = try? JSONEncoder().encode(mutableAction) {
                let msg = MessageRouter.createRequest(channel: "automation", payload: payloadData, correlationId: correlationId)
                await AppState.shared.connectionManager?.broadcast(msg)
                LinkOSLogger.shared.info("[AI] Forwarded request to Android device: \(action.actionType), correlationId: \(correlationId)", category: .ai)
                
                // Await response from the phone
                let (status, details) = await ResponseAwaiter.shared.awaitResponse(correlationId: correlationId)
                return (status, details)
            }
            return (false, "Failed to encode action for phone")
        }
        
        switch action.actionType {
        case "LAUNCH_APP":
            if var appName = action.parameters["app_name"], !appName.isEmpty {
                // Map common shortcuts or informal names
                let lowerApp = appName.lowercased()
                if lowerApp == "photobooth" || lowerApp == "photo booth" {
                    appName = "Photo Booth"
                } else if lowerApp == "safari" {
                    appName = "Safari"
                } else if lowerApp == "finder" {
                    appName = "Finder"
                } else if lowerApp == "chrome" || lowerApp == "google chrome" || lowerApp == "googlechrome" {
                    appName = "Google Chrome"
                } else if lowerApp == "vs code" || lowerApp == "vscode" || lowerApp == "visual studio code" {
                    appName = "Visual Studio Code"
                } else if lowerApp == "whatsapp" {
                    appName = "WhatsApp"
                } else if lowerApp == "instagram" {
                    // Instagram doesn't have a native Mac app by default, let's open Instagram website in browser!
                    if let url = URL(string: "https://www.instagram.com") {
                        NSWorkspace.shared.open(url)
                        return (true, "Opened Instagram in browser")
                    }
                }
                
                // Let's first try launching via open -a, which is case-insensitive and robust
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                var args = ["-a", appName]
                if let urlStr = action.parameters["url"], !urlStr.isEmpty {
                    args.append(urlStr)
                }
                task.arguments = args
                let errorPipe = Pipe()
                task.standardError = errorPipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    if task.terminationStatus == 0 {
                        return (true, "Launched \(appName)")
                    } else {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        if let errorStr = String(data: errorData, encoding: .utf8), !errorStr.isEmpty {
                            return (false, "Open error: \(errorStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    }
                } catch {
                    return (false, "Failed to run open command: \(error.localizedDescription)")
                }
                
                // Fallback to legacy NSWorkspace launch
                if NSWorkspace.shared.launchApplication(appName) {
                    return (true, "Launched \(appName)")
                } else {
                    return (false, "Could not locate or launch app '\(appName)'")
                }
            }
            return (false, "Missing application name parameter")
            
        case "TAKE_SCREENSHOT":
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let downloadsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/LinkOS")
            try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            let dest = downloadsDir.appendingPathComponent("Screenshot_\(Int(Date().timeIntervalSince1970 * 1000)).png")
            task.arguments = [dest.path]
            let errorPipe = Pipe()
            task.standardError = errorPipe
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 {
                    // Show a local OS notification for successful screenshot
                    let content = UNMutableNotificationContent()
                    content.title = "Screenshot Captured"
                    content.body = "✓ Screenshot saved to Downloads/LinkOS"
                    content.sound = .default
                    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                    try? await UNUserNotificationCenter.current().add(request)
                    
                    return (true, "✓ Screenshot saved to Downloads/LinkOS")
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorStr = String(data: errorData, encoding: .utf8) ?? ""
                    return (false, "screencapture failed with exit code \(task.terminationStatus). \(errorStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            } catch {
                return (false, "Failed to execute screencapture: \(error.localizedDescription)")
            }
            
        case "OPEN_FOLDER":
            if var path = action.parameters["path"], !path.isEmpty {
                if path.hasPrefix("~") {
                    path = path.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
                }
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: url.path) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    return (true, "Opened folder \(path)")
                } else {
                    return (false, "Directory does not exist: \(path)")
                }
            }
            return (false, "Missing folder path parameter")
            
        case "SYSTEM_CONTROL":
            if let setting = action.parameters["setting"] {
                switch setting {
                case "mute":
                    let script = NSAppleScript(source: "set volume output muted (not (output muted of (get volume settings)))")
                    var error: NSDictionary? = nil
                    script?.executeAndReturnError(&error)
                    if let err = error {
                        let errDetails = err.description
                        return (false, "Mute failed: \(errDetails)")
                    }
                    return (true, "Volume mute toggled")
                case "lock":
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                    task.arguments = ["displaysleepnow"]
                    let errorPipe = Pipe()
                    task.standardError = errorPipe
                    do {
                        try task.run()
                        task.waitUntilExit()
                        if task.terminationStatus == 0 {
                            return (true, "Locked Mac display")
                        } else {
                            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                            let errorStr = String(data: errorData, encoding: .utf8) ?? ""
                            return (false, "pmset failed with status \(task.terminationStatus). \(errorStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                    } catch {
                        return (false, "Failed to run lock command: \(error.localizedDescription)")
                    }
                case "sleep":
                    let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
                    var error: NSDictionary? = nil
                    script?.executeAndReturnError(&error)
                    if let err = error {
                        return (false, "Sleep failed: \(err.description)")
                    }
                    return (true, "✓ Mac put to sleep")
                case "shutdown":
                    let script = NSAppleScript(source: "tell application \"System Events\" to shut down")
                    var error: NSDictionary? = nil
                    script?.executeAndReturnError(&error)
                    if let err = error {
                        return (false, "Shutdown failed: \(err.description)")
                    }
                    return (true, "✓ Mac shutting down")
                case "restart_wifi":
                    let taskOff = Process()
                    taskOff.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    taskOff.arguments = ["-setairportpower", "en0", "off"]
                    try? taskOff.run()
                    taskOff.waitUntilExit()
                    
                    let taskOn = Process()
                    taskOn.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                    taskOn.arguments = ["-setairportpower", "en0", "on"]
                    do {
                        try taskOn.run()
                        taskOn.waitUntilExit()
                        return (true, "✓ Wi-Fi restarted")
                    } catch {
                        return (false, "Failed to restart Wi-Fi: \(error.localizedDescription)")
                    }
                case "playpause":
                    let source = """
                    tell application "System Events"
                        if exists (process "Music") then
                            tell application "Music" to playpause
                        else if exists (process "Spotify") then
                            tell application "Spotify" to playpause
                        end if
                    end tell
                    """
                    let script = NSAppleScript(source: source)
                    var error: NSDictionary? = nil
                    script?.executeAndReturnError(&error)
                    if let err = error {
                        return (false, "Music toggle failed: \(err.description)")
                    }
                    return (true, "Media playback toggled")
                default:
                    return (false, "Unknown system control setting: \(setting)")
                }
            }
            return (false, "Missing system control setting parameter")
            
        case "OPEN_URL":
            if let urlStr = action.parameters["url"], let url = URL(string: urlStr) {
                if NSWorkspace.shared.open(url) {
                    return (true, "Opened \(urlStr)")
                } else {
                    return (false, "Could not open URL '\(urlStr)'")
                }
            }
            return (false, "Missing or invalid URL parameter")
            
        default:
            return (false, "Unknown action type: \(action.actionType)")
        }
    }
}

final class AIAgentPlugin: LinkOSPlugin {
    let pluginId = "ai_agent"
    let displayName = "AI Mac Agent"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["ai", "automation"]
    let requiredPermissions: Set<String> = ["AI_COMMANDS", "APP_LAUNCH", "SYSTEM_CONTROL"]
    
    private(set) var isActive = false
    private let engine = AIEngine.shared
    private let executor = CommandExecutor()
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("AIAgentPlugin activated", category: .ai)
    }
    
    func deactivate() async {
        isActive = false
        LinkOSLogger.shared.info("AIAgentPlugin deactivated", category: .ai)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        if message.channel == "automation" {
            // Process response from the phone
            if let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
               let correlationId = message.correlationId {
                let status = (json["status"] as? String == "success")
                let details = json["message"] as? String ?? (status ? "Success" : "Failed")
                ResponseAwaiter.shared.resume(correlationId: correlationId, status: status, message: details)
            }
            return
        }
        
        guard let prompt = String(data: message.payload, encoding: .utf8) else { return }
        
        if let response = try? await engine.executeNaturalLanguageCommand(prompt: prompt) {
            var success = true
            var results: [String] = []
            var errors: [String] = []
            
            for action in response.suggestedActions {
                let (status, details) = await executor.execute(action: action)
                if status {
                    results.append(details)
                } else {
                    success = false
                    errors.append(details)
                }
            }
            
            let responseText: String
            if response.suggestedActions.isEmpty {
                responseText = "I interpreted your prompt but couldn't find a matching action. Try 'Launch Safari', 'Lock Mac', or 'Screenshot'."
            } else if success {
                responseText = "Completed: \(results.joined(separator: "; "))"
            } else {
                responseText = "Execution failed: \(errors.joined(separator: "; "))"
            }
            
            let finalResponse = AIResponse(
                text: responseText,
                suggestedActions: response.suggestedActions,
                confidence: response.confidence
            )
            
            if let respData = try? JSONEncoder().encode(finalResponse) {
                let payload = MessageRouter.createResponse(channel: "ai", payload: respData, correlationId: message.correlationId)
                try? await connectionManager?.send(payload, to: message.deviceId)
            }
        }
    }
    
    func commandPaletteActions() -> [CommandPaletteAction] {
        [
            CommandPaletteAction(
                id: "ai.take_screenshot",
                title: "AI Action: Take Screenshot",
                subtitle: "Capture Mac display to Desktop",
                icon: "camera",
                keywords: ["ai", "screenshot", "capture"],
                category: "AI Agent",
                action: { [weak self] in
                    _ = await self?.executor.execute(action: AIActionPayload(actionType: "TAKE_SCREENSHOT", parameters: [:]))
                }
            )
        ]
    }
}

class ResponseAwaiter {
    static let shared = ResponseAwaiter()
    private var continuations: [String: CheckedContinuation<(Bool, String), Never>] = [:]
    private let queue = DispatchQueue(label: "com.linkos.responseawaiter")
    
    func awaitResponse(correlationId: String, timeoutSec: Double = 8.0) async -> (Bool, String) {
        return await withCheckedContinuation { continuation in
            queue.sync {
                continuations[correlationId] = continuation
            }
            
            // Timeout protection
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                var contToResume: CheckedContinuation<(Bool, String), Never>?
                queue.sync {
                    contToResume = continuations.removeValue(forKey: correlationId)
                }
                if let cont = contToResume {
                    cont.resume(returning: (false, "Request timed out waiting for phone response"))
                }
            }
        }
    }
    
    func resume(correlationId: String, status: Bool, message: String) {
        var contToResume: CheckedContinuation<(Bool, String), Never>?
        queue.sync {
            contToResume = continuations.removeValue(forKey: correlationId)
        }
        if let cont = contToResume {
            cont.resume(returning: (status, message))
        }
    }
}
