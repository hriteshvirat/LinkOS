package com.linkos.core.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.linkos.core.logging.LinkOSLogger
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Discovered LinkOS service on the local network.
 */
data class DiscoveredService(
    val deviceId: String,
    val deviceName: String,
    val host: String,
    val port: Int,
    val model: String = "",
    val protocolVersion: Int = 1,
)

/**
 * NSD (Network Service Discovery) client for discovering macOS hosts
 * advertising the _linkos._tcp Bonjour service.
 */
@Singleton
class BonjourClient @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        const val SERVICE_TYPE = "_linkos._tcp"
    }

    private val nsdManager by lazy {
        context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }

    private val wifiManager by lazy {
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
    }

    private var networkCallback: android.net.ConnectivityManager.NetworkCallback? = null

    init {
        registerNetworkCallback()
    }

    private fun registerNetworkCallback() {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val request = android.net.NetworkRequest.Builder()
            .addTransportType(android.net.NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        
        networkCallback = object : android.net.ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: android.net.Network) {
                LinkOSLogger.info("Network shift detected: WiFi connection available.", "Network")
            }
            
            override fun onLost(network: android.net.Network) {
                LinkOSLogger.info("WiFi network connection lost", "Network")
            }
        }
        try {
            connectivityManager.registerNetworkCallback(request, networkCallback!!)
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to register network callback: ${e.message}", "Network")
        }
    }

    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    private val _discoveredServices = MutableStateFlow<List<DiscoveredService>>(emptyList())
    val discoveredServices: StateFlow<List<DiscoveredService>> = _discoveredServices.asStateFlow()

    private val _isDiscovering = MutableStateFlow(false)
    val isDiscovering: StateFlow<Boolean> = _isDiscovering.asStateFlow()

    private var discoveryListener: NsdManager.DiscoveryListener? = null

    /**
     * Start discovering LinkOS services on the local network.
     */
    fun startDiscovery() {
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            // Always stop + clean up any stale listener first, BEFORE checking the guard.
            // This prevents a stuck _isDiscovering=true from blocking all future restarts.
            stopDiscovery()
            kotlinx.coroutines.delay(500)

            if (_isDiscovering.value) {
                LinkOSLogger.info("NSD discovery already active after stop attempt, skipping", "Network")
                return@launch
            }
            _discoveredServices.value = emptyList()

            try {
                if (multicastLock == null) {
                    multicastLock = wifiManager.createMulticastLock("LinkOSBonjourLock").apply {
                        setReferenceCounted(true)
                    }
                }
                multicastLock?.acquire()
                LinkOSLogger.info("MulticastLock acquired for NSD discovery", "Network")
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to acquire MulticastLock: ${e.message}", "Network")
            }

            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) {
                    _isDiscovering.value = true
                    LinkOSLogger.info("NSD discovery started", "Network")
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    LinkOSLogger.info("NSD service found: ${serviceInfo.serviceName}", "Network")
                    resolveService(serviceInfo)
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                    LinkOSLogger.info("NSD service lost: ${serviceInfo.serviceName}", "Network")
                    _discoveredServices.value = _discoveredServices.value.filter {
                        it.deviceId != serviceInfo.serviceName
                    }
                }

                override fun onDiscoveryStopped(serviceType: String) {
                    _isDiscovering.value = false
                    LinkOSLogger.info("NSD discovery stopped", "Network")
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    _isDiscovering.value = false
                    LinkOSLogger.error("NSD discovery start failed: $errorCode", "Network")
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    LinkOSLogger.error("NSD discovery stop failed: $errorCode", "Network")
                }
            }

            discoveryListener = listener
            try {
                nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to call discoverServices: ${e.message}", "Network")
            }
        }
    }

    /**
     * Stop discovering services.
     */
    fun stopDiscovery() {
        discoveryListener?.let {
            try {
                nsdManager.stopServiceDiscovery(it)
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to stop NSD discovery: ${e.message}", "Network")
            }
        }
        discoveryListener = null
        // Proactively clear the flag — don't wait for onDiscoveryStopped callback which may be
        // delayed or dropped (e.g. when the app is in the background on some OEM ROMs).
        _isDiscovering.value = false

        if (registeredServiceInfo == null) {
            try {
                multicastLock?.let {
                    if (it.isHeld) {
                        it.release()
                        LinkOSLogger.info("MulticastLock released", "Network")
                    }
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to release MulticastLock: ${e.message}", "Network")
            }
        } else {
            LinkOSLogger.info("MulticastLock retained for active service advertisement", "Network")
        }
    }

    fun clearDiscoveredServices() {
        _discoveredServices.value = emptyList()
    }

    fun startTimedDiscovery(durationMs: Long = 15_000L) {
        startDiscovery()
        CoroutineScope(Dispatchers.IO).launch {
            delay(durationMs)
            if (_isDiscovering.value) {
                stopDiscovery()
            }
        }
    }

    private var registeredServiceInfo: NsdServiceInfo? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    /**
     * Start advertising this Android device on the local network.
     */
    fun startAdvertising(deviceName: String, deviceId: String) {
        if (registeredServiceInfo != null) {
            LinkOSLogger.info("NSD advertisement already active, skipping", "Network")
            return
        }
        stopAdvertising()

        val serviceInfo = NsdServiceInfo().apply {
            serviceName = deviceId
            serviceType = "_linkosclient._tcp"
            port = 52638
            setAttribute("device_id", deviceId)
            setAttribute("device_name", deviceName)
            setAttribute("model", android.os.Build.MODEL)
            setAttribute("protocol_version", "1")
        }

        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredServiceInfo = info
                LinkOSLogger.info("Android client service registered: ${info.serviceName}", "Network")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                LinkOSLogger.error("Android client service registration failed: $errorCode", "Network")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {
                LinkOSLogger.info("Android client service unregistered", "Network")
            }

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                LinkOSLogger.error("Android client service unregistration failed: $errorCode", "Network")
            }
        }

        registrationListener = listener
        try {
            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to register Android client service: ${e.message}", "Network")
        }
    }

    /**
     * Stop advertising this Android device.
     */
    fun stopAdvertising() {
        registrationListener?.let {
            try {
                nsdManager.unregisterService(it)
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to unregister Android client service: ${e.message}", "Network")
            }
        }
        registrationListener = null
        registeredServiceInfo = null
    }

    /**
     * Fully reset discovery and advertising states.
     */
    fun reset() {
        stopDiscovery()
        stopAdvertising()
        _discoveredServices.value = emptyList()
    }

    private fun resolveService(serviceInfo: NsdServiceInfo) {
        nsdManager.resolveService(serviceInfo, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                LinkOSLogger.error("NSD resolve failed: $errorCode for ${serviceInfo.serviceName}", "Network")
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val host = serviceInfo.host?.hostAddress ?: return
                val port = serviceInfo.port

                // Parse TXT records
                val attributes = serviceInfo.attributes
                val deviceId = attributes["device_id"]?.decodeToString() ?: serviceInfo.serviceName
                val deviceName = attributes["device_name"]?.decodeToString() ?: "Mac"
                val model = attributes["model"]?.decodeToString() ?: ""
                val protocolVersion = attributes["protocol_version"]?.decodeToString()?.toIntOrNull() ?: 1

                val discovered = DiscoveredService(
                    deviceId = deviceId,
                    deviceName = deviceName,
                    host = host,
                    port = port,
                    model = model,
                    protocolVersion = protocolVersion,
                )

                LinkOSLogger.info("NSD resolved: $deviceName at $host:$port", "Network")

                _discoveredServices.value = _discoveredServices.value
                    .filter { it.deviceId != deviceId } + discovered
            }
        })
    }
}
