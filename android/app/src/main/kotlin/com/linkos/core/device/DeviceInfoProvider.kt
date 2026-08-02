package com.linkos.core.device

import android.content.Context
import android.os.Build
import android.provider.Settings
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

public data class DeviceInfo(
    val deviceId: String,
    val deviceName: String,
    val model: String,
    val manufacturer: String,
    val osVersion: String
)

@Singleton
public class DeviceInfoProvider @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val prefs = context.getSharedPreferences("linkos_prefs", Context.MODE_PRIVATE)

    public fun getDeviceInfo(): DeviceInfo {
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: "android_device"
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        val model = Build.MODEL
        
        // Retrieve customized name if present, otherwise default to "Manufacturer Model"
        val defaultName = if (model.startsWith(manufacturer, ignoreCase = true)) model else "$manufacturer $model"
        val deviceName = prefs.getString("device_name", defaultName) ?: defaultName
        
        return DeviceInfo(
            deviceId = androidId,
            deviceName = deviceName,
            model = model,
            manufacturer = manufacturer,
            osVersion = "Android ${Build.VERSION.RELEASE}"
        )
    }

    public fun updateDeviceName(name: String) {
        prefs.edit().putString("device_name", name).apply()
    }

    public fun isOnboardingCompleted(): Boolean {
        val completed = prefs.getBoolean("onboarding_completed", false)
        val name = prefs.getString("device_name", null)
        return completed && !name.isNullOrEmpty()
    }

    public fun setOnboardingCompleted(completed: Boolean) {
        prefs.edit().putBoolean("onboarding_completed", completed).apply()
    }
}
