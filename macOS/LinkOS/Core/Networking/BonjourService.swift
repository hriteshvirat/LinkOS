import Foundation
import AppKit
import Network

public struct DiscoveredAndroidDevice: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let model: String
    public let host: String
    public let port: Int
}

/// Bonjour (mDNS) service for zero-config device discovery.
/// Publishes a `_linkos._tcp` service and browses for `_linkos_client._tcp` companion devices.
@MainActor
final class BonjourService: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
    
    private var netService: NetService?
    private var serviceBrowser: NetServiceBrowser?
    private var services: [NetService] = []
    private let logger = LinkOSLogger.shared
    private var pathMonitor: NWPathMonitor?
    
    /// The Bonjour service type macOS advertises
    static let serviceType = "_linkos._tcp"
    
    /// The Bonjour service type macOS browses for
    static let clientServiceType = "_linkosclient._tcp"
    
    /// Port the WebSocket server listens on
    private let port: Int32 = 52637
    
    override init() {
        super.init()
        registerSleepWakeNotifications()
        startMonitoringNetworkShifts()
    }
    
    private func startMonitoringNetworkShifts() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.logger.info("Network path shift detected. Restarting Bonjour mDNS service.", category: .network)
            Task { @MainActor in
                await self.stopAdvertising()
                await self.startAdvertising()
            }
        }
        let queue = DispatchQueue(label: "com.linkos.bonjour.monitor")
        monitor.start(queue: queue)
        self.pathMonitor = monitor
    }
    
    private func registerSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }
    
    @objc private func handleSleep() {
        logger.info("Mac is going to sleep. Suspending Bonjour advertisement.", category: .network)
        Task {
            await stopAdvertising()
        }
    }
    
    @objc private func handleWake() {
        logger.info("Mac woke up from sleep. Restoring Bonjour advertisement.", category: .network)
        Task {
            await startAdvertising()
        }
    }
    
    // MARK: - Service Advertisement
    
    /// Start advertising this Mac on the local network.
    func startAdvertising() async {
        let service = NetService(
            domain: "local.",
            type: Self.serviceType,
            name: DeviceIdentity.deviceId,
            port: port
        )
        
        let txtDict: [String: Data] = [
            "device_id": DeviceIdentity.deviceId.data(using: .utf8)!,
            "device_name": DeviceIdentity.deviceName.data(using: .utf8)!,
            "protocol_version": "1".data(using: .utf8)!,
            "model": macModel().data(using: .utf8)!
        ]
        
        service.setTXTRecord(NetService.data(fromTXTRecord: txtDict))
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.publish()
        self.netService = service
        logger.info("Bonjour mDNS advertising started for port \(port)", category: .network)
        
        // Also start browsing for companion devices
        startBrowsing()
    }
    
    /// Stop advertising.
    func stopAdvertising() {
        netService?.stop()
        netService = nil
        stopBrowsing()
        logger.info("Bonjour advertising stopped", category: .network)
    }
    
    /// Returns true if the NetService is currently published (non-nil).
    func isPublished() -> Bool {
        return netService != nil
    }
    
    /// Restart advertising.
    func restartAdvertising() async {
        stopAdvertising()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await startAdvertising()
    }
    
    // MARK: - Service Browsing
    
    private func startBrowsing() {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: Self.clientServiceType, inDomain: "local.")
        self.serviceBrowser = browser
        logger.info("Bonjour browsing started for \(Self.clientServiceType)", category: .network)
    }
    
    private func stopBrowsing() {
        serviceBrowser?.stop()
        serviceBrowser = nil
        services.removeAll()
    }
    
    // MARK: - NetServiceBrowserDelegate
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            service.schedule(in: .main, forMode: .common)
            service.resolve(withTimeout: 10.0)
            self.services.append(service)
        }
    }
    
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.services.removeAll { $0.name == service.name }
            AppState.shared.removeDiscoveredAndroidDevice(id: service.name)
        }
    }
    
    // MARK: - NetServiceDelegate
    
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        LinkOSLogger.shared.info("Bonjour net service published successfully: \(sender.name)", category: .network)
    }
    
    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        LinkOSLogger.shared.error("Bonjour net service failed to publish: \(errorDict)", category: .network)
    }
    
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }
        var hostname = ""
        for address in addresses {
            address.withUnsafeBytes { ptr in
                let sockaddr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                var ip = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sockaddr, socklen_t(sockaddr.pointee.sa_len), &ip, socklen_t(ip.count), nil, 0, NI_NUMERICHOST) == 0 {
                    hostname = String(cString: ip)
                }
            }
            if !hostname.isEmpty { break }
        }
        
        let port = sender.port
        let txtRecord = sender.txtRecordData()
        var deviceId = sender.name
        var deviceName = sender.name
        var model = ""
        
        if let txtRecord = txtRecord {
            let dict = NetService.dictionary(fromTXTRecord: txtRecord)
            if let idData = dict["device_id"], let idStr = String(data: idData, encoding: .utf8) {
                deviceId = idStr
            }
            if let nameData = dict["device_name"], let nameStr = String(data: nameData, encoding: .utf8) {
                deviceName = nameStr
            }
            if let modelData = dict["model"], let modelStr = String(data: modelData, encoding: .utf8) {
                model = modelStr
            }
        }
        
        let host = hostname
        LinkOSLogger.shared.info("[STAGE 1] Android discovered: name=\(deviceName) id=\(deviceId) at \(host):\(port)", category: .network)
        Task { @MainActor in
            AppState.shared.addDiscoveredAndroidDevice(
                id: deviceId,
                name: deviceName,
                model: model,
                host: host,
                port: Int(port)
            )
        }
    }
    
    // MARK: - Helpers
    
    private func macModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

// MARK: - Device Identity

/// Manages persistent device identity (UUID + name).
enum DeviceIdentity {
    private static let deviceIdKey = "linkos_device_id"
    
    /// Persistent device UUID. Generated once, stored in UserDefaults.
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }
    
    /// Human-readable device name.
    static var deviceName: String {
        if let customName = UserDefaults.standard.string(forKey: "linkos_custom_device_name"), !customName.isEmpty {
            return customName
        }
        if let customName = UserDefaults.standard.string(forKey: "linkos_profile_name"), !customName.isEmpty {
            return customName
        }
        return Host.current().localizedName ?? "Mac"
    }
}
