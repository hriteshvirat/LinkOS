package com.linkos.core.security

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages encrypted local storage on Android using EncryptedSharedPreferences backed by Android Keystore.
 */
@Singleton
class KeystoreManager @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val sharedPreferences = try {
        createEncryptedPrefs(context, masterKey)
    } catch (e: Exception) {
        // Log the failure to diagnose, do not silence the error info
        android.util.Log.e("Security", "Failed to initialize EncryptedSharedPreferences due to: ${e.message}. Re-creating...", e)
        deleteSharedPreferences(context, "linkos_secure_prefs")
        deleteSharedPreferences(context, "__androidx_security_crypto_encrypted_file_pref__")
        
        try {
            val keyStore = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            keyStore.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        } catch (ke: Exception) {
            android.util.Log.e("Security", "Failed to delete master key from KeyStore: ${ke.message}", ke)
        }
        
        val newMasterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        createEncryptedPrefs(context, newMasterKey)
    }

    companion object {
        private fun createEncryptedPrefs(context: Context, masterKey: MasterKey): android.content.SharedPreferences {
            return EncryptedSharedPreferences.create(
                context,
                "linkos_secure_prefs",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        }

        private fun deleteSharedPreferences(context: Context, name: String) {
            try {
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    context.deleteSharedPreferences(name)
                } else {
                    val sharedPrefsDir = java.io.File(context.applicationInfo.dataDir, "shared_prefs")
                    val xmlFile = java.io.File(sharedPrefsDir, "$name.xml")
                    val backupXmlFile = java.io.File(sharedPrefsDir, "$name.bak")
                    xmlFile.delete()
                    backupXmlFile.delete()
                }
            } catch (e: Exception) {
                // Ignore failure
            }
        }
    }

    fun storeString(key: String, value: String) {
        sharedPreferences.edit().putString(key, value).apply()
    }

    fun getString(key: String): String? {
        return sharedPreferences.getString(key, null)
    }

    fun storeBytes(key: String, bytes: ByteArray) {
        val encoded = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
        storeString(key, encoded)
    }

    fun getBytes(key: String): ByteArray? {
        val encoded = getString(key) ?: return null
        return android.util.Base64.decode(encoded, android.util.Base64.NO_WRAP)
    }

    fun remove(key: String) {
        sharedPreferences.edit().remove(key).apply()
    }

    fun storeDeviceIdentityKey(keyBytes: ByteArray) {
        storeBytes("device_identity_key", keyBytes)
    }

    fun getDeviceIdentityKey(): ByteArray? {
        return getBytes("device_identity_key")
    }
}
