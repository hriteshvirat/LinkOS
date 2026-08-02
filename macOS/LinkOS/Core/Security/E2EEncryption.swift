import Foundation
import CryptoKit

/// End-to-end encryption using ECDH P-256 key exchange and AES-256-GCM.
///
/// Flow:
/// 1. Each device generates an ephemeral ECDH P-256 key pair
/// 2. Devices exchange public keys during pairing
/// 3. Shared secret derived via ECDH
/// 4. Session keys derived via HKDF-SHA256
/// 5. All messages encrypted with AES-256-GCM
final class E2EEncryption {
    
    /// Generate a new ECDH P-256 key pair for key exchange.
    static func generateKeyPair() -> (privateKey: P256.KeyAgreement.PrivateKey,
                                       publicKey: P256.KeyAgreement.PublicKey) {
        let privateKey = P256.KeyAgreement.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }
    
    /// Derive a shared secret from our private key and the peer's public key.
    /// Returns a 256-bit symmetric key suitable for AES-256-GCM.
    static func deriveSessionKey(
        ownPrivateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKey: P256.KeyAgreement.PublicKey,
        salt: Data? = nil,
        info: Data = "LinkOS-Session-v1".data(using: .utf8)!
    ) throws -> SymmetricKey {
        let sharedSecret = try ownPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let derivedKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt ?? Data(),
            sharedInfo: info,
            outputByteCount: 32  // 256-bit key
        )
        return derivedKey
    }
    
    /// Encrypt data using AES-256-GCM.
    /// Returns: nonce (12 bytes) + ciphertext + tag (16 bytes)
    static func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw EncryptionError.sealFailed
        }
        return combined
    }
    
    /// Decrypt data using AES-256-GCM.
    /// Input: nonce (12 bytes) + ciphertext + tag (16 bytes)
    static func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    /// Compute HMAC-SHA256 for message integrity.
    static func hmac(for data: Data, using key: SymmetricKey) -> Data {
        let authCode = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(authCode)
    }
    
    /// Verify HMAC-SHA256 for message integrity.
    static func verifyHMAC(_ mac: Data, for data: Data, using key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: key)
    }
    
    /// Generate SHA-256 fingerprint of a public key (for device verification display).
    static func fingerprint(of publicKey: P256.KeyAgreement.PublicKey) -> String {
        let hash = SHA256.hash(data: publicKey.rawRepresentation)
        return hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    /// Serialize a public key for network transmission.
    static func serializePublicKey(_ key: P256.KeyAgreement.PublicKey) -> Data {
        key.derRepresentation
    }
    
    /// Deserialize a public key from network data.
    static func deserializePublicKey(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        try P256.KeyAgreement.PublicKey(derRepresentation: data)
    }
}

// MARK: - Errors

enum EncryptionError: LocalizedError {
    case sealFailed
    case invalidPublicKey
    case keyDerivationFailed
    
    var errorDescription: String? {
        switch self {
        case .sealFailed: return "AES-GCM seal failed"
        case .invalidPublicKey: return "Invalid public key data"
        case .keyDerivationFailed: return "HKDF key derivation failed"
        }
    }
}

// MARK: - Session

/// Manages an active encrypted session with a peer device.
final class EncryptedSession {
    let deviceId: String
    let sessionKey: SymmetricKey
    let createdAt: Date
    private(set) var lastActivity: Date
    
    init(deviceId: String, sessionKey: SymmetricKey) {
        self.deviceId = deviceId
        self.sessionKey = sessionKey
        self.createdAt = Date()
        self.lastActivity = Date()
    }
    
    func encrypt(_ data: Data) throws -> Data {
        lastActivity = Date()
        return try E2EEncryption.encrypt(data, using: sessionKey)
    }
    
    func decrypt(_ data: Data) throws -> Data {
        lastActivity = Date()
        return try E2EEncryption.decrypt(data, using: sessionKey)
    }
    
    func sign(_ data: Data) -> Data {
        lastActivity = Date()
        return E2EEncryption.hmac(for: data, using: sessionKey)
    }
    
    func verify(signature: Data, for data: Data) -> Bool {
        E2EEncryption.verifyHMAC(signature, for: data, using: sessionKey)
    }
}
