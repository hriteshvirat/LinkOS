package com.linkos.features.home

import android.content.Context
import android.os.BatteryManager
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.device.DeviceInfo
import com.linkos.core.device.DeviceInfoProvider
import com.linkos.core.network.BonjourClient
import com.linkos.core.network.ConnectionState
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.DiscoveredService
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

import com.linkos.core.security.KeystoreManager

@HiltViewModel
class HomeViewModel @Inject constructor(
    private val bonjourClient: BonjourClient,
    private val webSocketClient: WebSocketClient,
    private val connectionStateManager: ConnectionStateManager,
    private val deviceInfoProvider: DeviceInfoProvider,
    private val keystoreManager: KeystoreManager,
    @ApplicationContext private val context: Context
) : ViewModel() {

    val deviceInfo: DeviceInfo = deviceInfoProvider.getDeviceInfo()

    val discoveredDevices: StateFlow<List<DiscoveredService>> = bonjourClient.discoveredServices
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val isDiscovering: StateFlow<Boolean> = bonjourClient.isDiscovering
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val connectionState: StateFlow<ConnectionState> = webSocketClient.state
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), ConnectionState.DISCONNECTED)

    val hasConnectionFailed: StateFlow<Boolean> = webSocketClient.hasConnectionFailed
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val lastFailureStage: StateFlow<String?> = webSocketClient.lastFailureStage
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val connectedMacName: StateFlow<String> = webSocketClient.connectedMacName
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "Mac Host")

    val showPinCodeToUser: StateFlow<String?> = webSocketClient.showPinCodeToUser
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val requestPinCodeFromUser: StateFlow<Boolean> = webSocketClient.requestPinCodeFromUser
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    val macBatteryPercent: StateFlow<Int> = connectionStateManager.macBatteryPercent
    val isMacCharging: StateFlow<Boolean> = connectionStateManager.isMacCharging
    val isMacOnACPower: StateFlow<Boolean> = connectionStateManager.isMacOnACPower
    val androidBatteryPercentState: StateFlow<Int> = connectionStateManager.androidBatteryPercent
    val isAndroidChargingState: StateFlow<Boolean> = connectionStateManager.isAndroidCharging

    val androidBatteryPercent: Int
        get() = connectionStateManager.androidBatteryPercent.value

    val isAndroidCharging: Boolean
        get() = connectionStateManager.isAndroidCharging.value

    init {
        // No local initialization needed anymore since battery & state monitoring are handled globally.
    }

    val isManualDisconnect: Boolean
        get() = webSocketClient.isManualDisconnect

    fun disconnectDevice() {
        webSocketClient.isManualDisconnect = true
        connectionStateManager.disconnect()
        bonjourClient.stopDiscovery()
        bonjourClient.clearDiscoveredServices()
    }

    fun scanForDevices() {
        connectionStateManager.resetManualDisconnect()
        try {
            val serviceIntent = Intent(context, com.linkos.core.service.LinkOSService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(context, serviceIntent)
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to start service on scan: ${e.message}", "HomeViewModel")
        }
        bonjourClient.clearDiscoveredServices()
        val info = deviceInfoProvider.getDeviceInfo()
        bonjourClient.startAdvertising(info.deviceName, info.deviceId)
        bonjourClient.startDiscovery()
    }

    fun startDiscovery() {
        connectionStateManager.resetManualDisconnect()
        try {
            val serviceIntent = Intent(context, com.linkos.core.service.LinkOSService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(context, serviceIntent)
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to start service on discovery: ${e.message}", "HomeViewModel")
        }
        bonjourClient.startDiscovery()
    }

    fun stopDiscovery() {
        bonjourClient.stopDiscovery()
        bonjourClient.stopAdvertising()
    }

    fun connectToDevice(device: DiscoveredService, pairingCode: String? = null, method: String? = null) {
        connectionStateManager.connect(device.host, device.port, pairingCode, method)
    }

    fun connectToDeviceDirect(host: String, port: Int, pairingCode: String? = null, method: String? = null) {
        connectionStateManager.connect(host, port, pairingCode, method)
    }

    fun sendPairingRequest(code: String) {
        webSocketClient.sendPairingRequest(code)
    }

    fun retry() {
        webSocketClient.retry()
    }

    fun disconnect() {
        connectionStateManager.disconnect()
    }
}
