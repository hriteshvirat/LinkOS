import Foundation
import CoreBluetooth
import AppKit

/// BLE Presence service on macOS — scans for Android device BLE GATT advertisement,
/// estimates proximity via RSSI, and triggers auto-lock when device moves out of range.
final class BLEPresenceService: NSObject, CBCentralManagerDelegate {
    
    private var centralManager: CBCentralManager!
    private var targetDeviceUUID: String?
    private var isAutoLockEnabled: Bool = true
    private var distanceThresholdMeters: Double = 5.0
    
    var onPresenceStateChanged: ((Bool, Double) -> Void)?
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    
    func startMonitoring(targetUUID: String, autoLock: Bool = true, distanceThreshold: Double = 5.0) {
        self.targetDeviceUUID = targetUUID
        self.isAutoLockEnabled = autoLock
        self.distanceThresholdMeters = distanceThreshold
        
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            LinkOSLogger.shared.info("BLE Presence monitoring started", category: .presence)
        }
    }
    
    func stopMonitoring() {
        centralManager.stopScan()
        LinkOSLogger.shared.info("BLE Presence monitoring stopped", category: .presence)
    }
    
    // MARK: - CBCentralManagerDelegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, let targetUUID = targetDeviceUUID {
            startMonitoring(targetUUID: targetUUID, autoLock: isAutoLockEnabled, distanceThreshold: distanceThresholdMeters)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let rssiValue = RSSI.doubleValue
        let estimatedDistance = calculateDistance(rssi: rssiValue)
        
        let isNearby = estimatedDistance <= distanceThresholdMeters
        onPresenceStateChanged?(isNearby, estimatedDistance)
        
        if !isNearby && isAutoLockEnabled {
            lockMacScreen()
        }
    }
    
    // MARK: - Helpers
    
    private func calculateDistance(rssi: Double, txPower: Double = -59.0) -> Double {
        if rssi == 0 { return -1.0 }
        let ratio = rssi * 1.0 / txPower
        if ratio < 1.0 {
            return pow(ratio, 10)
        } else {
            return (0.89976) * pow(ratio, 7.7095) + 0.111
        }
    }
    
    private func lockMacScreen() {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        script?.executeAndReturnError(nil)
        LinkOSLogger.shared.info("Auto-locked Mac due to BLE proximity threshold exceeded", category: .presence)
    }
}

final class PresencePlugin: LinkOSPlugin {
    let pluginId = "presence"
    let displayName = "BLE Presence & Auto-Lock"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["presence"]
    let requiredPermissions: Set<String> = ["SYSTEM_CONTROL"]
    
    private(set) var isActive = false
    private let presenceService = BLEPresenceService()
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("PresencePlugin activated", category: .presence)
    }
    
    func deactivate() async {
        isActive = false
        presenceService.stopMonitoring()
        LinkOSLogger.shared.info("PresencePlugin deactivated", category: .presence)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        // Handle presence configuration update
    }
}
