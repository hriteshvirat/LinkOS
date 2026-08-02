import XCTest
import CryptoKit
@testable import LinkOS

final class LinkOSTests: XCTestCase {
    
    func testEncryptionRoundTrip() throws {
        // 1. Generate Key Pairs for Mac and Android
        let macKeys = E2EEncryption.generateKeyPair()
        let androidKeys = E2EEncryption.generateKeyPair()
        
        // 2. Derive Shared Session Keys
        let macSessionKey = try E2EEncryption.deriveSessionKey(ownPrivateKey: macKeys.privateKey, peerPublicKey: androidKeys.publicKey)
        let androidSessionKey = try E2EEncryption.deriveSessionKey(ownPrivateKey: androidKeys.privateKey, peerPublicKey: macKeys.publicKey)
        
        // 3. Verify Symmetric Key Parity
        let testPlaintext = "LinkOS Secret Payload 12345".data(using: .utf8)!
        let encryptedData = try E2EEncryption.encrypt(testPlaintext, using: macSessionKey)
        let decryptedData = try E2EEncryption.decrypt(encryptedData, using: androidSessionKey)
        
        XCTAssertEqual(testPlaintext, decryptedData)
    }
    
    func testHMACIntegrity() throws {
        let keys = E2EEncryption.generateKeyPair()
        let sessionKey = try E2EEncryption.deriveSessionKey(ownPrivateKey: keys.privateKey, peerPublicKey: keys.publicKey)
        
        let message = "Tamper Proof Packet".data(using: .utf8)!
        let hmac = E2EEncryption.hmac(for: message, using: sessionKey)
        
        XCTAssertTrue(E2EEncryption.verifyHMAC(hmac, for: message, using: sessionKey))
    }
    
    func testPublicKeyFingerprint() throws {
        let keys = E2EEncryption.generateKeyPair()
        let fp = E2EEncryption.fingerprint(of: keys.publicKey)
        XCTAssertFalse(fp.isEmpty)
        XCTAssertEqual(fp.split(separator: ":").count, 8)
    }
}
