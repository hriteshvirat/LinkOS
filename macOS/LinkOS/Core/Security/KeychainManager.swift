import Foundation
import Security

/// Manages secure storage of cryptographic keys and sensitive data
/// using the macOS Keychain (hardware-backed on Apple Silicon).
final class KeychainManager {
    
    static let shared = KeychainManager()
    private let service = "com.linkos.macos"
    private let logger = LinkOSLogger.shared
    
    private init() {}
    
    // MARK: - Generic Keychain Operations
    
    /// Store data in the Keychain.
    func store(key: String, data: Data, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        // Delete existing item first
        try? delete(key: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Keychain store failed for key: \(key)", category: .security,
                        metadata: ["status": "\(status)"])
            throw KeychainError.storeFailed(status)
        }
    }
    
    /// Retrieve data from the Keychain.
    func retrieve(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.retrieveFailed(status)
        }
        return data
    }
    
    /// Delete an item from the Keychain.
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    // MARK: - Typed Convenience Methods
    
    /// Store a Codable object.
    func store<T: Codable>(key: String, value: T) throws {
        let data = try JSONEncoder().encode(value)
        try store(key: key, data: data)
    }
    
    /// Retrieve a Codable object.
    func retrieve<T: Codable>(key: String, type: T.Type) throws -> T {
        let data = try retrieve(key: key)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    // MARK: - Device Identity
    
    /// Store the device's long-term identity private key.
    func storeDeviceIdentityKey(_ keyData: Data) throws {
        try store(key: "device_identity_key", data: keyData,
                  accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
    
    /// Retrieve the device's long-term identity private key.
    func retrieveDeviceIdentityKey() throws -> Data {
        try retrieve(key: "device_identity_key")
    }
    
    /// Store a paired device's public key.
    func storePeerPublicKey(deviceId: String, keyData: Data) throws {
        try store(key: "peer_key_\(deviceId)", data: keyData)
    }
    
    /// Retrieve a paired device's public key.
    func retrievePeerPublicKey(deviceId: String) throws -> Data {
        try retrieve(key: "peer_key_\(deviceId)")
    }
    
    /// Remove a paired device's stored keys.
    func removePeerKeys(deviceId: String) throws {
        try delete(key: "peer_key_\(deviceId)")
        try? delete(key: "session_\(deviceId)")
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    
    var errorDescription: String? {
        switch self {
        case .storeFailed(let s): return "Keychain store failed: \(s)"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        }
    }
}
