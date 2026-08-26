import Foundation
import Combine

/// Model representing a trusted paired client device
public struct TrustedDevice: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var model: String
    public var manufacturer: String
    public var osVersion: String
    public var lastConnected: Date
    public var isBlocked: Bool
    
    public init(id: String, name: String, model: String, manufacturer: String, osVersion: String, lastConnected: Date = Date(), isBlocked: Bool = false) {
        self.id = id
        self.name = name
        self.model = model
        self.manufacturer = manufacturer
        self.osVersion = osVersion
        self.lastConnected = lastConnected
        self.isBlocked = isBlocked
    }
}

/// Keychain and Storage manager for trusted & blocked companion devices
@MainActor
public final class TrustedDeviceStore: ObservableObject {
    public static let shared = TrustedDeviceStore()
    
    @Published public private(set) var trustedDevices: [TrustedDevice] = []
    
    private let storageKey = "linkos_trusted_devices_v1"
    
    private init() {
        loadDevices()
    }
    
    public func isTrusted(deviceId: String) -> Bool {
        guard let device = trustedDevices.first(where: { $0.id == deviceId }) else { return false }
        return !device.isBlocked
    }
    
    public func addTrustedDevice(_ device: TrustedDevice) {
        var list = trustedDevices.filter { $0.id != device.id }
        var updatedDevice = device
        updatedDevice.lastConnected = Date()
        list.append(updatedDevice)
        trustedDevices = list
        saveDevices()
    }
    
    public func updateLastConnected(deviceId: String) {
        if let idx = trustedDevices.firstIndex(where: { $0.id == deviceId }) {
            trustedDevices[idx].lastConnected = Date()
            saveDevices()
        }
    }
    
    public func revokeTrust(deviceId: String) {
        trustedDevices.removeAll { $0.id == deviceId }
        saveDevices()
        UserDefaults.standard.removeObject(forKey: "PhoneWindowFrameRect_\(deviceId)")
        UserDefaults.standard.removeObject(forKey: "pm_didUserResize_\(deviceId)")
    }
    
    public func blockDevice(deviceId: String) {
        if let idx = trustedDevices.firstIndex(where: { $0.id == deviceId }) {
            trustedDevices[idx].isBlocked = true
            saveDevices()
        }
    }
    
    public func unblockDevice(deviceId: String) {
        if let idx = trustedDevices.firstIndex(where: { $0.id == deviceId }) {
            trustedDevices[idx].isBlocked = false
            saveDevices()
        }
    }
    
    private func loadDevices() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([TrustedDevice].self, from: data) {
            self.trustedDevices = decoded
        }
    }
    
    private func saveDevices() {
        if let encoded = try? JSONEncoder().encode(trustedDevices) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
