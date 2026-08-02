import Foundation
import AppKit

/// Triggers macOS quick actions (lock, sleep, dark mode, etc.) and periodically broadcasts system metrics telemetry to Android.
@MainActor
final class SystemControlService: NSObject, ConnectionStateSubscriber {
    static let shared = SystemControlService()
    
    var subscriberId = "system_control_service"
    private var telemetryTimer: Timer?
    private let logger = LinkOSLogger.shared
    
    private override init() {
        super.init()
        ConnectionStateManager.shared.subscribe(self)
        startTelemetryLoop()
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        // Handle connections
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .session else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let action = json["action"] as? String {
                
                if action == "quick_action", let command = json["command"] as? String {
                    executeQuickAction(command)
                }
            }
        } catch {
            logger.error("Failed to parse system control command: \(error.localizedDescription)", category: .plugin)
        }
    }
    
    func qosDidChange(state: QoSState) async {
        // QoS updates
    }
    
    private func executeQuickAction(_ command: String) {
        var scriptSource = ""
        switch command {
        case "lock":
            scriptSource = "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"
            // Fallback shell utility
            if !runAppleScript(scriptSource) {
                runShellCommand("pmset displaysleepnow")
            }
        case "sleep":
            scriptSource = "tell application \"Finder\" to sleep"
            _ = runAppleScript(scriptSource)
        case "restart":
            scriptSource = "tell application \"Finder\" to restart"
            _ = runAppleScript(scriptSource)
        case "shutdown":
            scriptSource = "tell application \"Finder\" to shut down"
            _ = runAppleScript(scriptSource)
        case "empty_trash":
            scriptSource = "tell application \"Finder\" to empty trash"
            _ = runAppleScript(scriptSource)
        case "dark_mode_toggle":
            scriptSource = """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to not dark mode
                end tell
            end tell
            """
            _ = runAppleScript(scriptSource)
        default:
            break
        }
        logger.info("Executed system control quick action: \(command)", category: .plugin)
    }
    
    private func startTelemetryLoop() {
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.broadcastTelemetry()
            }
        }
    }
    
    private func broadcastTelemetry() async {
        guard ConnectionStateManager.shared.phase == .connected else { return }
        
        let cpu = getCPULoad()
        let ram = getMemoryUsage()
        let disk = getStorageSpace()
        
        let payload: [String: Any] = [
            "action": "telemetry",
            "cpu_load": cpu,
            "ram_used_bytes": ram.used,
            "ram_total_bytes": ram.total,
            "disk_used_bytes": disk.used,
            "disk_total_bytes": disk.total,
            "timestamp_ms": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            await ConnectionStateManager.shared.routeMessage(channel: .session, payload: data, from: DeviceIdentity.deviceId)
        }
    }
    
    // Telemetry Statistics Helpers
    
    private func getCPULoad() -> Double {
        var hostInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        
        let total = hostInfo.cpu_ticks.0 + hostInfo.cpu_ticks.1 + hostInfo.cpu_ticks.2 + hostInfo.cpu_ticks.3
        let user = hostInfo.cpu_ticks.0 + hostInfo.cpu_ticks.1
        guard total > 0 else { return 0.0 }
        return Double(user) / Double(total)
    }
    
    private func getMemoryUsage() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wire = UInt64(stats.wire_count) * pageSize
        
        let used = active + inactive + wire
        return (used, total)
    }
    
    private func getStorageSpace() -> (used: UInt64, total: UInt64) {
        let path = NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let size = attrs[.systemSize] as? UInt64,
              let free = attrs[.systemFreeSize] as? UInt64 else {
            return (0, 1)
        }
        return (size - free, size)
    }
    
    @discardableResult
    private func runAppleScript(_ source: String) -> Bool {
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
    
    private func runShellCommand(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zsh", "-c", command]
        try? process.run()
    }
}
