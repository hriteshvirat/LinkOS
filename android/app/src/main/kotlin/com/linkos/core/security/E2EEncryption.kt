package com.linkos.core.security

import java.security.KeyPairGenerator
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.KeyFactory
import java.security.interfaces.ECPrivateKey
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * End-to-end encryption using ECDH P-256 key exchange and AES-256-GCM.
 *
 * Flow:
 * 1. Each device generates an ephemeral ECDH P-256 key pair
 * 2. Public keys exchanged during pairing
 * 3. Shared secret derived via ECDH
 * 4. Session keys derived via HKDF-SHA256
 * 5. All messages encrypted with AES-256-GCM
 */
object E2EEncryption {

    private const val EC_ALGORITHM = "EC"
    private const val EC_CURVE = "secp256r1"  // P-256
    private const val KEY_AGREEMENT = "ECDH"
    private const val AES_ALGORITHM = "AES/GCM/NoPadding"
    private const val HMAC_ALGORITHM = "HmacSHA256"
    private const val GCM_TAG_LENGTH = 128  // bits
    private const val GCM_NONCE_LENGTH = 12  // bytes
    private const val SESSION_KEY_LENGTH = 32  // bytes (256 bits)

    /**
     * Generate a new ECDH P-256 key pair.
     */
    fun generateKeyPair(): java.security.KeyPair {
        val generator = KeyPairGenerator.getInstance(EC_ALGORITHM)
        generator.initialize(ECGenParameterSpec(EC_CURVE))
        return generator.generateKeyPair()
    }

    /**
     * Derive a shared session key from our private key and peer's public key.
     * Uses ECDH + HKDF-SHA256.
     */
    fun deriveSessionKey(
        ownPrivateKey: ECPrivateKey,
        peerPublicKey: ECPublicKey,
        salt: ByteArray = ByteArray(0),
        info: ByteArray = "LinkOS-Session-v1".toByteArray()
    ): ByteArray {
        // ECDH key agreement
        val agreement = KeyAgreement.getInstance(KEY_AGREEMENT)
        agreement.init(ownPrivateKey)
        agreement.doPhase(peerPublicKey, true)
        val sharedSecret = agreement.generateSecret()

        // HKDF extract + expand
        return hkdf(sharedSecret, salt, info, SESSION_KEY_LENGTH)
    }

    /**
     * Encrypt data using AES-256-GCM.
     * Returns: nonce (12 bytes) || ciphertext || tag (16 bytes)
     */
    fun encrypt(plaintext: ByteArray, key: ByteArray): ByteArray {
        val nonce = ByteArray(GCM_NONCE_LENGTH).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance(AES_ALGORITHM)
        val spec = GCMParameterSpec(GCM_TAG_LENGTH, nonce)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), spec)
        val ciphertext = cipher.doFinal(plaintext)
        return nonce + ciphertext
    }

    /**
     * Decrypt data using AES-256-GCM.
     * Input: nonce (12 bytes) || ciphertext || tag (16 bytes)
     */
    fun decrypt(data: ByteArray, key: ByteArray): ByteArray {
        val nonce = data.copyOfRange(0, GCM_NONCE_LENGTH)
        val ciphertext = data.copyOfRange(GCM_NONCE_LENGTH, data.size)
        val cipher = Cipher.getInstance(AES_ALGORITHM)
        val spec = GCMParameterSpec(GCM_TAG_LENGTH, nonce)
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), spec)
        return cipher.doFinal(ciphertext)
    }

    /**
     * Compute HMAC-SHA256 for message integrity.
     */
    fun hmac(data: ByteArray, key: ByteArray): ByteArray {
        val mac = Mac.getInstance(HMAC_ALGORITHM)
        mac.init(SecretKeySpec(key, HMAC_ALGORITHM))
        return mac.doFinal(data)
    }

    /**
     * Verify HMAC-SHA256.
     */
    fun verifyHmac(expectedMac: ByteArray, data: ByteArray, key: ByteArray): Boolean {
        val computed = hmac(data, key)
        return MessageDigest.isEqual(computed, expectedMac)
    }

    /**
     * SHA-256 fingerprint of a public key for display verification.
     */
    fun fingerprint(publicKey: ECPublicKey): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val hash = digest.digest(publicKey.encoded)
        return hash.take(8).joinToString(":") { "%02X".format(it) }
    }

    /**
     * Serialize public key for network transmission.
     */
    fun serializePublicKey(key: ECPublicKey): ByteArray = key.encoded

    /**
     * Deserialize public key from network data.
     */
    fun deserializePublicKey(data: ByteArray): ECPublicKey {
        val keyFactory = KeyFactory.getInstance(EC_ALGORITHM)
        return keyFactory.generatePublic(X509EncodedKeySpec(data)) as ECPublicKey
    }

    // MARK: - HKDF

    private fun hkdf(
        inputKeyMaterial: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        outputLength: Int
    ): ByteArray {
        // Extract
        val prk = hmac(inputKeyMaterial, if (salt.isEmpty()) ByteArray(32) else salt)

        // Expand
        var output = ByteArray(0)
        var t = ByteArray(0)
        var counter: Byte = 1

        while (output.size < outputLength) {
            t = hmac(t + info + byteArrayOf(counter), prk)
            output += t
            counter++
        }

        return output.copyOfRange(0, outputLength)
    }
}

/**
 * Manages an active encrypted session with a peer device.
 */
class EncryptedSession(
    val deviceId: String,
    private val sessionKey: ByteArray,
) {
    val createdAt: Long = System.currentTimeMillis()
    var lastActivity: Long = System.currentTimeMillis()
        private set

    fun encrypt(data: ByteArray): ByteArray {
        lastActivity = System.currentTimeMillis()
        return E2EEncryption.encrypt(data, sessionKey)
    }

    fun decrypt(data: ByteArray): ByteArray {
        lastActivity = System.currentTimeMillis()
        return E2EEncryption.decrypt(data, sessionKey)
    }

    fun sign(data: ByteArray): ByteArray {
        lastActivity = System.currentTimeMillis()
        return E2EEncryption.hmac(data, sessionKey)
    }

    fun verify(signature: ByteArray, data: ByteArray): Boolean =
        E2EEncryption.verifyHmac(signature, data, sessionKey)
}
