import SwiftUI
import Combine
import Network
import CryptoKit

public struct PendingPairingRequest: Identifiable, Equatable {
    public let id: String
    public let deviceName: String
    public let deviceModel: String
    public let manufacturer: String
    public let osVersion: String
    public let pairingCode: String?
    
    public init(id: String, deviceName: String, deviceModel: String, manufacturer: String, osVersion: String, pairingCode: String? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.manufacturer = manufacturer
        self.osVersion = osVersion
        self.pairingCode = pairingCode
    }
}

public struct PairingSession: Equatable {
    public let id: String
    public let timestamp: Date
}

/// Global application state container.
/// Observable singleton that drives UI updates across all views.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    
    // MARK: - Connection State
    
public enum PairingState: String, Codable {
    case idle
    case searching
    case connecting
    case pinGenerated
    case qrGenerated
    case waitingForUser
    case pinVerification
    case approvalRequired
    case keyExchange
    case authenticated
    case connected
    case trusted
}

    @Published var isConnected = false
    @Published var connectedDeviceId: String = ""
    @Published var activeConnectedDevice: TrustedDevice?
    @Published var connectedDeviceName: String = ""
    @Published var pendingPairingRequest: PendingPairingRequest?
    @Published var connectionQuality: ConnectionQualityLevel = .disconnected
    @Published var activePairingCode: String?
    @Published var discoveredAndroidDevices: [DiscoveredAndroidDevice] = []
    @Published var pairingMode: String = "none" // "none", "QR", "PIN_generator", "PIN_entry"
    @Published var pairingState: PairingState = .idle
    @Published var androidBatteryPercent: Int? = nil
    @Published var isAndroidCharging: Bool? = nil
    @Published var androidPowerSource: String? = nil
    
    // MARK: - Remote Telemetry State
    @Published var remoteCpuUsage: Double = 0.0
    @Published var remoteRamUsage: Double = 0.0
    @Published var remoteDiskUsage: Double = 0.0
    @Published var remoteTemperature: Double = 0.0
    @Published var remoteWifiStrength: Int = 0
    @Published var remotePingRtt: Double = 0.0
    
    var activePendingConnection: WebSocketConnection?
    var pendingPairingAndroidDevice: String?
    var tempPrivateKey: P256.KeyAgreement.PrivateKey?
    
    var activeSession: PairingSession?
    private var watchdogTimer: Timer?
    
    // MARK: - Service References
    
    var connectionManager: ConnectionManager?
    var bonjourService: BonjourService?
    var pluginManager: PluginManager?
    var messageRouter: MessageRouter?
    
    // MARK: - UI State
    
    @Published var isPairingPresented = false
    @Published var activeFeature: FeatureTab = .dashboard
    @Published var showDebugOverlay = false
    @Published var selectedSidebarItem: String = "Dashboard"
    @Published var macBatteryPercent: Double = 100.0
    @Published var isMacCharging: Bool = false
    @Published var isMacOnACPower: Bool = false
    
    // MARK: - Remote File Explorer State
    @Published var remoteFiles: [FileItemInfo] = []
    @Published var remoteThumbnails: [String: NSImage] = [:]
    @Published var remoteCurrentPath: String = "/"
    @Published var isDownloadingFile = false
    @Published var fileDownloadProgress: Double = 0.0
    @Published var showHiddenFiles = false
    @Published var fileClipboardSourcePath: String? = nil
    @Published var fileClipboardOperation: String? = nil
    
    // MARK: - Local File Explorer State
    @Published var localCurrentPath: String = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.appendingPathComponent("LinkOS").path ?? ""
    
    // MARK: - Settings
    
    @Published var settings = LinkOSSettings.load()
    
    // MARK: - Onboarding & Identity State
    @Published var profileName: String = "" {
        didSet {
            UserDefaults.standard.set(profileName, forKey: "linkos_profile_name")
        }
    }
    @Published var profileAvatar: String = "" {
        didSet {
            UserDefaults.standard.set(profileAvatar, forKey: "linkos_profile_avatar")
        }
    }
    @Published var customDeviceName: String = "" {
        didSet {
            UserDefaults.standard.set(customDeviceName, forKey: "linkos_custom_device_name")
            Task {
                await bonjourService?.restartAdvertising()
            }
        }
    }
    @Published var hasCompletedOnboarding: Bool = false {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "linkos_has_completed_onboarding")
        }
    }
    
    private init() {
        self.profileName = UserDefaults.standard.string(forKey: "linkos_profile_name") ?? (NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
        self.profileAvatar = UserDefaults.standard.string(forKey: "linkos_profile_avatar") ?? "💻"
        self.customDeviceName = UserDefaults.standard.string(forKey: "linkos_custom_device_name") ?? Host.current().localizedName ?? "Mac"
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "linkos_has_completed_onboarding")
        
        let battery = SystemMetricsService.shared.getBatteryInfo()
        self.macBatteryPercent = battery.percent
        self.isMacCharging = battery.isCharging
        self.isMacOnACPower = battery.isOnACPower
    }
    
    // MARK: - Session Management
    
    public func createSession(reason: String) -> String {
        destroySession(reason: "Starting new pairing attempt")
        let sessionId = String(format: "%04X", Int.random(in: 0...0xFFFF))
        self.activeSession = PairingSession(id: sessionId, timestamp: Date())
        LinkOSLogger.shared.info("[SESSION #\(sessionId)] CREATED. Reason: \(reason)", category: .security)
        return sessionId
    }
    
    public func destroySession(reason: String) {
        guard let session = activeSession else { return }
        let sessionId = session.id
        LinkOSLogger.shared.info("[SESSION #\(sessionId)] DESTROYED. Reason: \(reason)", category: .security)
        
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        
        if let conn = activePendingConnection {
            conn.close()
        }
        activePendingConnection = nil
        
        pendingPairingRequest = nil
        activePairingCode = nil
        tempPrivateKey = nil
        pendingPairingAndroidDevice = nil
        pairingMode = "none"
        pairingState = .idle
        
        PairingApprovalWindowManager.shared.closeWindow()
        PairingWindowManager.shared.closeWindow()
        
        activeSession = nil
    }
    
    public func startWatchdog(timeout: TimeInterval, stage: Int, reason: String) {
        watchdogTimer?.invalidate()
        guard let session = activeSession else { return }
        let sessionId = session.id
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.activeSession?.id == sessionId else { return }
                LinkOSLogger.shared.warning("[SESSION #\(sessionId)] Watchdog fired: Stage \(stage) failure - \(reason)", category: .security)
                self.destroySession(reason: "Timeout waiting for Stage \(stage): \(reason)")
            }
        }
    }
    
    public func pairingCompleted() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let session = activeSession {
            LinkOSLogger.shared.info("[SESSION #\(session.id)] COMPLETED SUCCESSFULLY", category: .security)
        }
        activeSession = nil
        PairingApprovalWindowManager.shared.closeWindow()
        PairingWindowManager.shared.closeWindow()
    }
    
    public func requestPairing(from request: PendingPairingRequest) {
        let macHostName = DeviceIdentity.deviceName
        let sessionId = activeSession?.id ?? "NONE"
        LinkOSLogger.shared.info("[SESSION #\(sessionId)] Pairing request received: deviceName=\(request.deviceName) id=\(request.id) code=\(request.pairingCode ?? "nil")", category: .security)
        LinkOSLogger.shared.info("[SESSION #\(sessionId)] Current active pairing code: \(self.activePairingCode ?? "nil")", category: .security)
        
        if let activeCode = self.activePairingCode {
            if request.pairingCode != activeCode {
                LinkOSLogger.shared.error("[SESSION #\(sessionId)] Pairing code mismatch! Expected: \(activeCode), Got: \(request.pairingCode ?? "nil")", category: .security)
                if let conn = activePendingConnection {
                    Task {
                        await WebSocketServer.shared.sendPairingRejected(to: conn)
                    }
                }
                destroySession(reason: "Pairing code mismatch")
                return
            } else {
                // Code matches! Auto-accept the pairing directly without presenting approval HUD
                LinkOSLogger.shared.info("[SESSION #\(sessionId)] Pairing code matched! Auto-accepting pairing without popup.", category: .security)
                acceptPairing(request, remember: true)
                pairingCompleted()
                
                let ownKeys = E2EEncryption.generateKeyPair()
                self.tempPrivateKey = ownKeys.privateKey
                let pubKeyBase64 = E2EEncryption.serializePublicKey(ownKeys.publicKey).base64EncodedString()
                
                if let conn = activePendingConnection {
                    Task {
                        await WebSocketServer.shared.sendPairingApproved(to: conn, deviceId: request.id, macName: macHostName, publicKey: pubKeyBase64)
                    }
                }
                return
            }
        }
        
        if TrustedDeviceStore.shared.isTrusted(deviceId: request.id) {
            LinkOSLogger.shared.info("[SESSION #\(sessionId)] [TRUST_CREATED] Device \(request.id) is already trusted. Auto-accepting connection.", category: .security)
            acceptPairing(request, remember: true)
            
            // Session completes successfully (trusted auto-connect)
            pairingCompleted()
            
            let ownKeys = E2EEncryption.generateKeyPair()
            self.tempPrivateKey = ownKeys.privateKey
            let pubKeyBase64 = E2EEncryption.serializePublicKey(ownKeys.publicKey).base64EncodedString()
            
            if let conn = activePendingConnection {
                Task {
                    await WebSocketServer.shared.sendPairingApproved(to: conn, deviceId: request.id, macName: macHostName, publicKey: pubKeyBase64)
                }
            }
        } else {
            // Untrusted device pairing request received — present approval HUD on macOS
            LinkOSLogger.shared.info("[SESSION #\(sessionId)] [STAGE 7] Untrusted device pairing request received. Presenting approval HUD on macOS.", category: .security)
            self.pendingPairingRequest = request
            
            startWatchdog(timeout: 30, stage: 8, reason: "Timed out waiting for Mac user approval.")
            
            PairingApprovalWindowManager.shared.showApprovalWindow(request: request) { [weak self] allow, remember in
                self?.respondToPairing(allow: allow, remember: remember)
            }
        }
    }
    
    public func respondToPairing(allow: Bool, remember: Bool) {
        PairingApprovalWindowManager.shared.closeWindow()
        guard let req = pendingPairingRequest else { return }
        let conn = activePendingConnection
        self.pendingPairingRequest = nil
        self.activePendingConnection = nil
        
        let sessionId = activeSession?.id ?? "NONE"
        let macHostName = DeviceIdentity.deviceName
        if allow {
            LinkOSLogger.shared.info("[SESSION #\(sessionId)] [STAGE 8] Approval clicked (User accepted pairing request from device \(req.deviceName))", category: .security)
            acceptPairing(req, remember: remember)
            
            startWatchdog(timeout: 10, stage: 10, reason: "Cryptographic key exchange timed out.")
            
            let ownKeys = E2EEncryption.generateKeyPair()
            self.tempPrivateKey = ownKeys.privateKey
            let pubKeyBase64 = E2EEncryption.serializePublicKey(ownKeys.publicKey).base64EncodedString()
            
            if let conn = conn {
                Task {
                    await WebSocketServer.shared.sendPairingApproved(to: conn, deviceId: req.id, macName: macHostName, publicKey: pubKeyBase64)
                }
            }
        } else {
            rejectPairing(req)
            if let conn = conn {
                Task {
                    await WebSocketServer.shared.sendPairingRejected(to: conn)
                }
            }
            destroySession(reason: "User rejected connection request")
        }
    }
    
    private func acceptPairing(_ req: PendingPairingRequest, remember: Bool) {
        let device = TrustedDevice(
            id: req.id,
            name: req.deviceName,
            model: req.deviceModel,
            manufacturer: req.manufacturer,
            osVersion: req.osVersion,
            lastConnected: Date()
        )
        if remember {
            TrustedDeviceStore.shared.addTrustedDevice(device)
        }
        LinkOSLogger.shared.info("[TRUST_CREATED] Trust storage updated for device: \(req.deviceName) (ID: \(req.id))", category: .security)
        self.activeConnectedDevice = device
        self.isConnected = true
        self.connectionQuality = .excellent
        self.pairingCompleted()
    }
    
    private func rejectPairing(_ req: PendingPairingRequest) {
        self.activeConnectedDevice = nil
        self.connectedDeviceId = ""
        self.isConnected = false
        self.connectionQuality = .disconnected
    }
    
    public func disconnectActiveDevice() {
        self.connectedDeviceId = ""
        guard let device = self.activeConnectedDevice else {
            self.activeConnectedDevice = nil
            self.connectedDeviceName = ""
            self.isConnected = false
            self.connectionQuality = .disconnected
            self.androidBatteryPercent = nil
            self.isAndroidCharging = nil
            self.androidPowerSource = nil
            self.remoteThumbnails = [:]
            
            ConnectionStateManager.shared.transition(to: .disconnected)
            
            Task {
                await self.bonjourService?.restartAdvertising()
            }
            
            if let manager = self.connectionManager {
                Task {
                    await manager.disconnectAllConnections()
                }
            }
            return
        }
        
        // NOTE: Do NOT revoke trust on manual disconnect.
        // Manual disconnect should only tear down the active session.
        // Trust keys are preserved so the user can reconnect without re-pairing.
        
        // Create manual disconnect payload
        let payload: [String: Any] = [
            "action": "disconnect",
            "manual": true
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let envelope = try? MessageRouter.createEvent(channel: ProtocolConstants.Channel.session, payload: data) {
            Task {
                try? await self.connectionManager?.send(envelope, to: device.id)
                
                // Let the send finish, then clean up
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.activeConnectedDevice = nil
                    self.connectedDeviceName = ""
                    self.connectedDeviceId = ""
                    self.isConnected = false
                    self.connectionQuality = .disconnected
                    self.androidBatteryPercent = nil
                    self.isAndroidCharging = nil
                    self.androidPowerSource = nil
                    self.remoteThumbnails = [:]
                    
                    ConnectionStateManager.shared.transition(to: .disconnected)
                    
                    Task {
                        await self.bonjourService?.restartAdvertising()
                    }
                    
                    if let manager = self.connectionManager {
                        Task {
                            await manager.disconnectAllConnections()
                        }
                    }
                }
            }
        } else {
            self.activeConnectedDevice = nil
            self.connectedDeviceName = ""
            self.connectedDeviceId = ""
            self.isConnected = false
            self.connectionQuality = .disconnected
            self.androidBatteryPercent = nil
            self.isAndroidCharging = nil
            self.androidPowerSource = nil
            self.remoteThumbnails = [:]
            
            ConnectionStateManager.shared.transition(to: .disconnected)
            
            Task {
                await self.bonjourService?.restartAdvertising()
            }
            
            if let manager = self.connectionManager {
                Task {
                    await manager.disconnectAllConnections()
                }
            }
        }
    }
    
    public func handleActiveDeviceDisconnected(deviceId: String) {
        if self.activeConnectedDevice?.id == deviceId || self.connectedDeviceId == deviceId || self.activeConnectedDevice == nil {
            self.activeConnectedDevice = nil
            self.connectedDeviceName = ""
            self.connectedDeviceId = ""
            self.isConnected = false
            self.connectionQuality = .disconnected
            self.androidBatteryPercent = nil
            self.isAndroidCharging = nil
            self.androidPowerSource = nil
            self.remoteThumbnails = [:]
            
            ConnectionStateManager.shared.transition(to: .disconnected)
            
            Task {
                await self.bonjourService?.restartAdvertising()
            }
        }
    }
    
    // MARK: - mDNS Discovery Management
    
    public func addDiscoveredAndroidDevice(id: String, name: String, model: String, host: String, port: Int) {
        let device = DiscoveredAndroidDevice(id: id, name: name, model: model, host: host, port: port)
        if !discoveredAndroidDevices.contains(where: { $0.id == id }) {
            discoveredAndroidDevices.append(device)
            LinkOSLogger.shared.info("Added discovered Android device: \(name) at \(host):\(port)", category: .network)
        }
    }
    
    public func removeDiscoveredAndroidDevice(id: String) {
        discoveredAndroidDevices.removeAll { $0.id == id }
    }
    
    // MARK: - Bidirectional Pairing Workflows
    
    public func handlePairingInit(initiator: String, method: String) {
        let sessionId = createSession(reason: "Received incoming PAIRING_INIT invite")
        
        if method == "PIN" {
            self.pairingState = .pinGenerated
            self.pairingMode = "PIN_generator"
            let code = String(format: "%06d", Int.random(in: 0...999999))
            self.activePairingCode = code
            LinkOSLogger.shared.info("[SESSION #\(sessionId)] [STAGE 4] PIN generated: \(code)", category: .security)
            
            PairingWindowManager.shared.showPairingWindow()
            LinkOSLogger.shared.info("[SESSION #\(sessionId)] [STAGE 5] PIN window shown (presenting code \(code) on screen)", category: .security)
            
            startWatchdog(timeout: 30, stage: 5, reason: "Timed out waiting for user to input PIN code.")
            
            if let conn = activePendingConnection {
                Task {
                    await WebSocketServer.shared.sendPairingPinDisplayed(to: conn)
                }
            }
        } else if method == "QR" {
            self.pairingState = .qrGenerated
            self.pairingMode = "QR"
            PairingWindowManager.shared.showPairingWindow()
            LinkOSLogger.shared.info("[SESSION #\(sessionId)] [STAGE 5] QR code window shown on screen", category: .security)
            
            startWatchdog(timeout: 35, stage: 5, reason: "Timed out waiting for user to scan QR code.")
            
            if let conn = activePendingConnection {
                Task {
                    await WebSocketServer.shared.sendPairingQrDisplayed(to: conn)
                }
            }
        }
    }
    
    public func connectToAndroidDevice(device: DiscoveredAndroidDevice, method: String) {
        let localIP = getLocalIPAddress()
        let invitePayload = "{\"action\":\"CONNECT_TO\",\"host\":\"\(localIP)\",\"port\":52637,\"mode\":\"\(method)\"}\n"
        
        self.pendingPairingAndroidDevice = device.id
        self.pairingMode = method == "PIN" ? "PIN_entry" : "QR"
        
        LinkOSLogger.shared.info("Sending invite to Android device \(device.name) on port 52638 with mode \(method)", category: .network)
        
        importNetworkAndSendInvite(host: device.host, port: 52638, payload: invitePayload)
        
        // Present the correct pairing HUD immediately
        PairingWindowManager.shared.showPairingWindow()
    }
    
    public func sendPairingRequest(code: String) {
        guard let conn = activePendingConnection else { return }
        let payload: [String: String] = [
            "type": "PAIRING_REQUEST",
            "deviceId": DeviceIdentity.deviceId,
            "deviceName": DeviceIdentity.deviceName,
            "pairingCode": code
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            Task {
                try? await conn.send(data)
            }
        }
    }
    
    private func importNetworkAndSendInvite(host: String, port: Int, payload: String) {
        let connection = importNetworkConnection(host: host, port: port)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let data = payload.data(using: .utf8)!
                connection.send(content: data, completion: .contentProcessed({ error in
                    connection.cancel()
                }))
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
    
    private func importNetworkConnection(host: String, port: Int) -> Network.NWConnection {
        return Network.NWConnection(
            host: Network.NWEndpoint.Host(host),
            port: Network.NWEndpoint.Port(rawValue: UInt16(port))!,
            using: .tcp
        )
    }
    
    public func getLocalIPAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                guard let interface = ptr?.pointee else { return "127.0.0.1" }
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" || name == "awdl0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                    &hostname, socklen_t(hostname.count),
                                    nil, 0, NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        return address ?? "127.0.0.1"
    }
}

// MARK: - Supporting Types

enum ConnectionQualityLevel: String, CaseIterable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case disconnected = "Disconnected"
    
    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .blue
        case .fair: return .yellow
        case .poor: return .orange
        case .disconnected: return .gray
        }
    }
    
    var icon: String {
        switch self {
        case .excellent: return "wifi"
        case .good: return "wifi"
        case .fair: return "wifi.exclamationmark"
        case .poor: return "wifi.slash"
        case .disconnected: return "wifi.slash"
        }
    }
}

enum FeatureTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case remoteDesktop = "Remote Desktop"
    case trackpad = "Trackpad"
    case clipboard = "Clipboard"
    case files = "Files"
    case downloads = "Downloads"
    case terminal = "Terminal"
    case notifications = "Notifications"
    case aiAgent = "AI Agent"
    case streamDeck = "Shortcuts"
    case media = "Media"
    case devMode = "Developer"
    case workspace = "Workspace"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .remoteDesktop: return "display"
        case .trackpad: return "rectangle.and.hand.point.up.left.filled"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "folder"
        case .downloads: return "arrow.down.circle"
        case .terminal: return "terminal"
        case .notifications: return "bell"
        case .aiAgent: return "brain"
        case .streamDeck: return "square.grid.3x3"
        case .media: return "play.circle"
        case .devMode: return "hammer"
        case .workspace: return "rectangle.stack"
        }
    }
}

/// Persistent user settings.
struct LinkOSSettings: Codable {
    var localOnly: Bool = true
    var maxBandwidthMbps: Int = 0
    var videoQuality: VideoQuality = .adaptive
    var maxFPS: Int = 60
    var theme: AppTheme = .system
    var enableDebugOverlay: Bool = false
    var enablePresenceDetection: Bool = false
    var presenceDistanceMeters: Double = 5.0
    
    // Trackpad Settings
    var cursorSensitivity: Double = 1.00
    var scrollingSensitivity: Double = 1.00
    var scrollDirectionNatural: Bool = true
    var tapToClick: Bool = true
    var twoFingerSecondaryClick: Bool = true
    var threeFingerDrag: Bool = true
    var pointerAcceleration: String = "Normal (Default)"
    var motionSmoothing: String = "Balanced (Default)"
    var precisionMode: Bool = false
    var gamingMode: Bool = false
    
    enum VideoQuality: String, Codable, CaseIterable {
        case low, medium, high, ultra, adaptive
    }
    
    enum AppTheme: String, Codable, CaseIterable {
        case light, dark, system
    }
    
    static func load() -> LinkOSSettings {
        guard let data = UserDefaults.standard.data(forKey: "linkos_settings"),
              let settings = try? JSONDecoder().decode(LinkOSSettings.self, from: data) else {
            return LinkOSSettings()
        }
        return settings
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "linkos_settings")
        }
    }
}
