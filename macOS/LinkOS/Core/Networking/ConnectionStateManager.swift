import Foundation
import Combine

// MARK: - Connection State

/// Unified connection states visible throughout the app.
enum ConnectionPhase: String, CaseIterable {
    case disconnected
    case discovering
    case connecting
    case pairing
    case connected
    case reconnecting
}

// MARK: - Channel Priority

/// Logical multiplex channels ordered by priority.
/// Lower rawValue = higher priority. Cursor packets must never be blocked.
enum MessageChannel: String, Codable, CaseIterable, Comparable {
    case cursor       // Priority 0 – real-time input
    case keyboard     // Priority 1 – text events
    case clipboard    // Priority 2 – sync payloads
    case fileTransfer // Priority 3 – chunked binary
    case remoteDesktop // Priority 4 – metadata/control
    case audio        // Priority 5 - real-time audio
    case camera       // Priority 6 - camera feed
    case notifications // Priority 7 - mirroring notifications
    case phone        // Priority 8 - telephony & calls
    case handoff      // Priority 9 - Safari tabs & handoffs
    case mediaControl // Priority 10 - system media controls
    case automation   // Priority 11 - automation events
    case heartbeat    // Priority 12 – keep-alive
    case session      // Priority 13 – pairing/identity
    
    var priority: Int {
        switch self {
        case .cursor:        return 0
        case .keyboard:      return 1
        case .clipboard:     return 2
        case .fileTransfer:  return 3
        case .remoteDesktop: return 4
        case .audio:         return 5
        case .camera:        return 6
        case .notifications: return 7
        case .phone:         return 8
        case .handoff:       return 9
        case .mediaControl:  return 10
        case .automation:    return 11
        case .heartbeat:     return 12
        case .session:       return 13
        }
    }
    
    static func < (lhs: MessageChannel, rhs: MessageChannel) -> Bool {
        lhs.priority < rhs.priority
    }
}

// MARK: - Device Identity

/// Represents a connected peer device.
struct PeerDevice: Equatable {
    let id: String
    var name: String
    var model: String
    var osVersion: String
    var protocolVersion: Int
    var capabilities: Set<String>
}

// MARK: - QoS Profile

/// Quality of Service profiles that adapt streaming/input parameters to current conditions.
enum QoSProfile: String, CaseIterable {
    case optimal       // Full quality – low latency, high bandwidth
    case balanced      // Moderate adaptation
    case degraded      // Reduced quality – high latency or low bandwidth
    case powerSaving   // Battery-conscious – minimal streaming
}

struct QoSState {
    var profile: QoSProfile = .optimal
    var currentRTT: TimeInterval = 0       // Round-trip time in seconds
    var currentFPS: Int = 60
    var targetBitrate: Int = 8_000_000     // bits/sec
    var packetLossRate: Double = 0         // 0.0 – 1.0
    var cpuUsage: Double = 0              // 0.0 – 1.0
    var isBatteryLow: Bool = false
    var coalescingThreshold: TimeInterval = 0.001 // 1ms default
    
    /// Evaluates current metrics and selects the appropriate QoS profile.
    mutating func evaluate() {
        if isBatteryLow {
            profile = .powerSaving
            currentFPS = 30
            targetBitrate = 3_000_000
            coalescingThreshold = 0.005
        } else if currentRTT > 0.1 || cpuUsage > 0.8 {
            profile = .degraded
            currentFPS = 30
            targetBitrate = 4_000_000
            coalescingThreshold = 0.003
        } else if currentRTT > 0.05 || packetLossRate > 0.02 {
            profile = .balanced
            currentFPS = 45
            targetBitrate = 6_000_000
            coalescingThreshold = 0.002
        } else {
            profile = .optimal
            currentFPS = 60
            targetBitrate = 8_000_000
            coalescingThreshold = 0.001
        }
    }
}

// MARK: - Subscriber Protocol

/// Any subsystem that wants to receive connection lifecycle events.
@MainActor
protocol ConnectionStateSubscriber: AnyObject {
    var subscriberId: String { get }
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async
    func qosDidChange(state: QoSState) async
}

// Extension with default no-op implementations so subscribers only override what they need.
extension ConnectionStateSubscriber {
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {}
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {}
    func qosDidChange(state: QoSState) async {}
}

// MARK: - Connection State Manager

/// Centralized connection state engine.
/// All subsystems subscribe here instead of managing their own socket lifecycles.
@MainActor
final class ConnectionStateManager: ObservableObject {
    static let shared = ConnectionStateManager()
    
    // Published state for SwiftUI bindings
    @Published private(set) var phase: ConnectionPhase = .disconnected
    @Published private(set) var connectedDevice: PeerDevice?
    @Published private(set) var qos: QoSState = QoSState()
    
    // Performance counters (observable by debug overlay)
    @Published var rttMs: Double = 0
    @Published var fps: Int = 0
    @Published var packetLossPercent: Double = 0
    @Published var reconnectCount: Int = 0
    @Published var bytesSent: UInt64 = 0
    @Published var bytesReceived: UInt64 = 0
    
    private var subscribers: [String: any ConnectionStateSubscriber] = [:]
    private let logger = LinkOSLogger.shared
    
    // Heartbeat & RTT measurement
    private var heartbeatTimer: Timer?
    private var lastPingSentAt: Date?
    
    // QoS evaluation timer
    private var qosTimer: Timer?
    
    private init() {
        startQoSEvaluation()
    }
    
    func subscribe(_ subscriber: ConnectionStateSubscriber) {
        subscribers[subscriber.subscriberId] = subscriber
        logger.debug("Subscriber registered: \(subscriber.subscriberId)", category: .network)
    }
    
    func unsubscribe(_ subscriberId: String) {
        subscribers.removeValue(forKey: subscriberId)
    }
    
    // MARK: - State Transitions
    
    func transition(to newPhase: ConnectionPhase, device: PeerDevice? = nil) {
        let oldPhase = phase
        phase = newPhase
        if let device = device {
            connectedDevice = device
        }
        
        if newPhase == .connected {
            startHeartbeat()
            Task { @MainActor in
                AppState.shared.bonjourService?.stopAdvertising()
            }
        } else if newPhase == .disconnected {
            stopHeartbeat()
            connectedDevice = nil
            Task { @MainActor in
                await AppState.shared.bonjourService?.restartAdvertising()
            }
        } else if newPhase == .reconnecting {
            reconnectCount += 1
        }
        
        logger.info("[ConnectionState] \(oldPhase.rawValue) → \(newPhase.rawValue)", category: .network)
        
        // Notify all subscribers
        let currentDevice = connectedDevice
        Task {
            await notifySubscribers { subscriber in
                await subscriber.connectionDidChange(phase: newPhase, device: currentDevice)
            }
        }
    }
    
    // MARK: - Device Identity Update
    
    func updateDeviceName(_ name: String) {
        connectedDevice?.name = name
        logger.info("[ConnectionState] Device name updated to: \(name)", category: .network)
    }
    
    func updateDeviceCapabilities(_ capabilities: Set<String>) {
        connectedDevice?.capabilities = capabilities
        logger.info("[ConnectionState] Device capabilities updated to: \(capabilities)", category: .network)
        
        // Notify all subscribers
        let currentDevice = connectedDevice
        Task {
            await notifySubscribers { subscriber in
                await subscriber.connectionDidChange(phase: self.phase, device: currentDevice)
            }
        }
    }
    
    // MARK: - Message Routing
    
    /// Route an incoming message to all subscribers listening on the specified channel.
    func routeMessage(channel: MessageChannel, payload: Data, from deviceId: String) {
        bytesReceived += UInt64(payload.count)
        
        Task {
            await notifySubscribers { subscriber in
                await subscriber.didReceiveMessage(channel: channel, payload: payload, from: deviceId)
            }
        }
    }
    
    /// Create a prioritized multiplexed envelope for outgoing messages.
    func createEnvelope(channel: MessageChannel, payload: Data) -> Data {
        let envelope: [String: Any] = [
            "channel": channel.rawValue,
            "priority": channel.priority,
            "timestamp": Date().timeIntervalSince1970 * 1000,
            "payload": String(data: payload, encoding: .utf8) ?? ""
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? payload
    }
    
    // MARK: - Heartbeat & RTT
    
    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendPing()
            }
        }
    }
    
    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
    
    private func sendPing() {
        lastPingSentAt = Date()
        // Ping is sent via the WebSocketServer; the response updates RTT
    }
    
    func recordPong() {
        if let sentAt = lastPingSentAt {
            let rtt = Date().timeIntervalSince(sentAt)
            rttMs = rtt * 1000
            qos.currentRTT = rtt
        }
    }
    
    // MARK: - QoS Evaluation
    
    private func startQoSEvaluation() {
        qosTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateQoS()
            }
        }
    }
    
    private func evaluateQoS() {
        let previousProfile = qos.profile
        qos.evaluate()
        
        if qos.profile != previousProfile {
            logger.info("[QoS] Profile changed: \(previousProfile.rawValue) → \(qos.profile.rawValue)", category: .performance)
            let currentQoS = qos
            Task {
                await notifySubscribers { subscriber in
                    await subscriber.qosDidChange(state: currentQoS)
                }
            }
        }
    }
    
    /// Update QoS input metrics from external sources.
    func updateQoSMetrics(rtt: TimeInterval? = nil, packetLoss: Double? = nil, cpuUsage: Double? = nil, batteryLow: Bool? = nil) {
        if let rtt = rtt { qos.currentRTT = rtt; rttMs = rtt * 1000 }
        if let pl = packetLoss { qos.packetLossRate = pl; packetLossPercent = pl * 100 }
        if let cpu = cpuUsage { qos.cpuUsage = cpu }
        if let bl = batteryLow { qos.isBatteryLow = bl }
    }
    
    // MARK: - Helpers
    
    private func notifySubscribers(_ action: @escaping (ConnectionStateSubscriber) async -> Void) async {
        for (_, subscriber) in subscribers {
            await action(subscriber)
        }
    }
}


