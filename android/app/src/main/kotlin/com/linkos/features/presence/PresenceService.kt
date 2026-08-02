package com.linkos.features.presence

import android.content.Context
import com.linkos.core.logging.LinkOSLogger
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PresenceService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var isAdvertising = false

    fun startAdvertising() {
        if (isAdvertising) return
        isAdvertising = true
        LinkOSLogger.info("BLE Presence advertiser started", "Presence")
    }

    fun stopAdvertising() {
        if (!isAdvertising) return
        isAdvertising = false
        LinkOSLogger.info("BLE Presence advertiser stopped", "Presence")
    }
}
