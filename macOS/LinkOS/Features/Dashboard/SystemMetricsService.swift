import Foundation
import IOKit.ps

struct MacSystemMetrics: Codable {
    let cpuUserPercent: Double
    let cpuSystemPercent: Double
    let cpuIdlePercent: Double
    let memoryTotalBytes: UInt64
    let memoryUsedBytes: UInt64
    let memoryFreeBytes: UInt64
    let batteryPercent: Double
    let isCharging: Bool
    let isOnACPower: Bool
    let diskTotalBytes: UInt64
    let diskFreeBytes: UInt64
    let timestampMs: Int64
}

final class SystemMetricsService {
    static let shared = SystemMetricsService()
    
    func collectMetrics() -> MacSystemMetrics {
        let cpu = getCPUUsage()
        let memory = getMemoryUsage()
        let battery = getBatteryInfo()
        let disk = getDiskUsage()
        
        return MacSystemMetrics(
            cpuUserPercent: cpu.user,
            cpuSystemPercent: cpu.system,
            cpuIdlePercent: cpu.idle,
            memoryTotalBytes: memory.total,
            memoryUsedBytes: memory.used,
            memoryFreeBytes: memory.free,
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            isOnACPower: battery.isOnACPower,
            diskTotalBytes: disk.total,
            diskFreeBytes: disk.free,
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
    
    // MARK: - CPU
    
    private func getCPUUsage() -> (user: Double, system: Double, idle: Double) {
        var cpuInfo: host_cpu_load_info_data_t = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return (user: 0.0, system: 0.0, idle: 100.0)
        }
        
        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let total = user + system + idle
        
        guard total > 0 else { return (0, 0, 100) }
        return (user: (user / total) * 100.0, system: (system / total) * 100.0, idle: (idle / total) * 100.0)
    }
    
    // MARK: - Memory
    
    private func getMemoryUsage() -> (total: UInt64, used: UInt64, free: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return (total: total, used: 0, free: total)
        }
        
        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        
        let used = active + inactive + wired + compressed
        return (total: total, used: used, free: free)
    }
    
    // MARK: - Battery
    
    public func getBatteryInfo() -> (percent: Double, isCharging: Bool, isOnACPower: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (percent: 100.0, isCharging: true, isOnACPower: true)
        }
        
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? Int) ?? (desc[kIOPSCurrentCapacityKey] as? Double).map(Int.init) ?? 100
            let maxCap = (desc[kIOPSMaxCapacityKey] as? Int) ?? (desc[kIOPSMaxCapacityKey] as? Double).map(Int.init) ?? 100
            let pct = maxCap > 0 ? (Double(current) / Double(maxCap)) * 100.0 : Double(current)
            let powerSourceState = desc[kIOPSPowerSourceStateKey] as? String
            let isOnACPower = powerSourceState == kIOPSACPowerValue
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? isOnACPower
            return (percent: min(100.0, max(0.0, pct)), isCharging: isCharging, isOnACPower: isOnACPower)
        }
        return (percent: 100.0, isCharging: true, isOnACPower: true)
    }
    
    // MARK: - Disk
    
    private func getDiskUsage() -> (total: UInt64, free: UInt64) {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: "/")
            let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
            return (total: total, free: free)
        } catch {
            return (total: 0, free: 0)
        }
    }
}
