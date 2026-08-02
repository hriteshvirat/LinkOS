package com.linkos

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.IntSize
import com.linkos.core.security.E2EEncryption
import com.linkos.features.remotedesktop.TouchInputMapper
import org.junit.Assert.*
import org.junit.Test
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey

class LinkOSTest {

    @Test
    fun testEncryptionRoundTrip() {
        val macKeys = E2EEncryption.generateKeyPair()
        val androidKeys = E2EEncryption.generateKeyPair()

        val macSessionKey = E2EEncryption.deriveSessionKey(
            macKeys.private as ECPrivateKey,
            androidKeys.public as ECPublicKey
        )
        val androidSessionKey = E2EEncryption.deriveSessionKey(
            androidKeys.private as ECPrivateKey,
            macKeys.public as ECPublicKey
        )

        assertArrayEquals(macSessionKey, androidSessionKey)

        letText = "Hello LinkOS E2E Encryption"
        val plaintextBytes = letText.toByteArray(Charsets.UTF8)

        val encrypted = E2EEncryption.encrypt(plaintextBytes, macSessionKey)
        val decrypted = E2EEncryption.decrypt(encrypted, androidSessionKey)

        assertArrayEquals(plaintextBytes, decrypted)
    }

    @Test
    fun testTouchInputMapperScaling() {
        val touch = Offset(540f, 1200f) // Center of 1080x2400 screen
        val container = IntSize(1080, 2400)

        val mapped = TouchInputMapper.mapTouchToMac(touch, container, 3024, 1964)

        assertFalse(mapped.isOutOfBounds)
        assertEquals(1512.0, mapped.macX, 0.1)
        assertEquals(982.0, mapped.macY, 0.1)
    }
}
