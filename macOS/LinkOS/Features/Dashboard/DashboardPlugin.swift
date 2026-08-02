import Foundation
import Combine

final class DashboardPlugin: LinkOSPlugin {
    let pluginId = "dashboard"
    let displayName = "System Dashboard"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["dashboard"]
    let requiredPermissions: Set<String> = ["SYSTEM_INFO"]
    
    private(set) var isActive = false
    private let metricsService = SystemMetricsService()
    private var timer: AnyCancellable?
    private weak var connectionManager: ConnectionManager?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        startStreamingMetrics()
        
        // Listen to macOS power source events immediately on the main run loop
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            let plugin = Unmanaged<DashboardPlugin>.fromOpaque(context).takeUnretainedValue()
            Task {
                await plugin.broadcastMetrics()
            }
        }
        if let runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.defaultMode)
            self.powerSourceRunLoopSource = runLoopSource
        }
        
        LinkOSLogger.shared.info("DashboardPlugin activated with battery observer", category: .app)
        
        // Broadcast immediately on activation
        Task {
            await broadcastMetrics()
        }
    }
    
    func deactivate() async {
        isActive = false
        timer?.cancel()
        timer = nil
        
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, CFRunLoopMode.defaultMode)
            powerSourceRunLoopSource = nil
        }
        
        LinkOSLogger.shared.info("DashboardPlugin deactivated", category: .app)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        if let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] {
            let batteryPct = json["batteryPercent"] as? Int ?? (json["batteryPercent"] as? Double).map(Int.init)
            let isCharging = json["isCharging"] as? Bool ?? false
            let powerSource = json["powerSource"] as? String
            let cpu = json["cpuUsage"] as? Double ?? 0.0
            let ram = json["ramUsage"] as? Double ?? 0.0
            let disk = json["diskUsage"] as? Double ?? 0.0
            let temp = json["temperature"] as? Double ?? 0.0
            let wifi = json["wifiStrength"] as? Int ?? 0
            let ping = json["pingRtt"] as? Double ?? 0.0
            
            await MainActor.run {
                if batteryPct != nil {
                    AppState.shared.androidBatteryPercent = batteryPct
                }
                AppState.shared.isAndroidCharging = isCharging
                AppState.shared.androidPowerSource = powerSource
                AppState.shared.remoteCpuUsage = cpu
                AppState.shared.remoteRamUsage = ram
                AppState.shared.remoteDiskUsage = disk
                AppState.shared.remoteTemperature = temp
                AppState.shared.remoteWifiStrength = wifi
                AppState.shared.remotePingRtt = ping
            }
        }
        
        let metrics = metricsService.collectMetrics()
        if let data = try? JSONEncoder().encode(metrics) {
            let response = MessageRouter.createResponse(channel: "dashboard", payload: data, correlationId: message.correlationId)
            try? await connectionManager?.send(response, to: message.deviceId)
        }
    }
    
    private func startStreamingMetrics() {
        timer = Timer.publish(every: ProtocolConstants.Telemetry.intervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.broadcastMetrics()
                }
            }
    }
    
    private func broadcastMetrics() async {
        guard let connectionManager else { return }
        let metrics = metricsService.collectMetrics()
        guard let data = try? JSONEncoder().encode(metrics) else { return }
        let payload = MessageRouter.createEvent(channel: "dashboard", payload: data)
        await connectionManager.broadcast(payload)
        
        await MainActor.run {
            AppState.shared.macBatteryPercent = metrics.batteryPercent
            AppState.shared.isMacCharging = metrics.isCharging
            AppState.shared.isMacOnACPower = metrics.isOnACPower
        }
    }
}
