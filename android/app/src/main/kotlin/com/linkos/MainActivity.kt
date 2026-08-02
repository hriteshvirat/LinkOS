package com.linkos

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import androidx.navigation.compose.rememberNavController
import com.linkos.ui.navigation.LinkOSNavHost
import com.linkos.ui.theme.LinkOSTheme
import dagger.hilt.android.AndroidEntryPoint

import javax.inject.Inject
import com.linkos.core.network.InviteListener
import com.linkos.core.network.BonjourClient
import com.linkos.core.device.DeviceInfoProvider

/**
 * Main entry point for the LinkOS Android app.
 * Sets up edge-to-edge display, Material 3 theming, and navigation.
 */
@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject
    lateinit var inviteListener: InviteListener

    @Inject
    lateinit var bonjourClient: BonjourClient

    @Inject
    lateinit var deviceInfoProvider: DeviceInfoProvider

    @Inject
    lateinit var androidFileHandler: com.linkos.features.files.AndroidFileHandler

    @Inject
    lateinit var androidAudioCaptureService: com.linkos.features.audio.AndroidAudioCaptureService

    @Inject
    lateinit var androidTelemetryCollector: com.linkos.core.device.AndroidTelemetryCollector

    @Inject
    lateinit var fileTransferQueueManager: com.linkos.features.files.FileTransferQueueManager

    @Inject
    lateinit var clipboardHistoryManager: com.linkos.features.clipboard.ClipboardHistoryManager

    @Inject
    lateinit var webSocketClient: com.linkos.core.network.WebSocketClient

    private val navigateToRoute = mutableStateOf<String?>(null)
    private var clipboardListener: android.content.ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastSyncedText: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        webSocketClient.isManualDisconnect = false
        enableEdgeToEdge()

        // Request POST_NOTIFICATIONS permission on Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val hasNotificationPermission = checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!hasNotificationPermission) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        // Request All Files Access permission on Android 11+ for File Explorer
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!android.os.Environment.isExternalStorageManager()) {
                try {
                    val intent = Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = android.net.Uri.parse("package:$packageName")
                    }
                    startActivity(intent)
                } catch (e: Exception) {
                    // Fallback to generic all files access settings
                    val intent = Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    startActivity(intent)
                }
            }
        } else {
            // Pre-Android 11: request legacy storage permissions
            val hasRead = checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED
            val hasWrite = checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED
            if (!hasRead || !hasWrite) {
                requestPermissions(arrayOf(
                    android.Manifest.permission.READ_EXTERNAL_STORAGE,
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                ), 102)
            }
        }

        // Start Background Service
        val serviceIntent = Intent(this, com.linkos.core.service.LinkOSService::class.java)
        ContextCompat.startForegroundService(this, serviceIntent)

        handleIntent(intent)

        setContent {
            LinkOSTheme {
                Surface(
                    modifier = Modifier.fillMaxSize()
                ) {
                    val navController = rememberNavController()
                    val route = navigateToRoute.value
                    
                    LaunchedEffect(route) {
                        if (route != null) {
                            navController.navigate(route) {
                                launchSingleTop = true
                            }
                            navigateToRoute.value = null
                        }
                    }

                    LinkOSNavHost(navController = navController, deviceInfoProvider = deviceInfoProvider)
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        val route = intent?.getStringExtra("navigate_to")
        if (route != null) {
            navigateToRoute.value = route
        }
    }

    override fun onResume() {
        super.onResume()
        
        // Ensure background service is running when app is in foreground
        try {
            val serviceIntent = Intent(this, com.linkos.core.service.LinkOSService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(this, serviceIntent)
        } catch (e: Exception) {
            com.linkos.core.logging.LinkOSLogger.error("Failed to start service on resume: ${e.message}", "MainActivity")
        }

        val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        checkAndSyncClipboard(clipboard)
        
        clipboardListener = android.content.ClipboardManager.OnPrimaryClipChangedListener {
            checkAndSyncClipboard(clipboard)
        }
        clipboard.addPrimaryClipChangedListener(clipboardListener)
    }

    override fun onPause() {
        super.onPause()
        clipboardListener?.let {
            val clipboard = getSystemService(android.content.Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
            clipboard.removePrimaryClipChangedListener(it)
        }
        clipboardListener = null
    }

    private fun checkAndSyncClipboard(clipboard: android.content.ClipboardManager) {
        val clip = clipboard.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).text?.toString()
            if (!text.isNullOrEmpty() && text != lastSyncedText) {
                lastSyncedText = text
                
                val item = com.linkos.features.clipboard.ClipboardHistoryItem(
                    id = java.util.UUID.randomUUID().toString(),
                    contentType = com.linkos.features.clipboard.ClipboardType.TEXT,
                    previewText = if (text.length > 200) text.substring(0, 200) else text,
                    fullText = text,
                    mimeType = "text/plain",
                    sourceApp = packageName,
                    timestamp = System.currentTimeMillis(),
                    isPinned = false,
                    isFavourite = false,
                    sizeBytes = text.toByteArray().size
                )
                
                clipboardHistoryManager.addItem(item)
                
                com.linkos.core.logging.LinkOSLogger.info("[ClipboardSync] [${System.currentTimeMillis()}] [CLIP-${item.id.take(6)}] Transmitting local clipboard change to Mac: size=${item.sizeBytes} bytes", "ClipboardSync")
                webSocketClient.sendEnvelope("clipboard", text, type = "event")
            }
        }
    }

    override fun onStart() {
        super.onStart()
    }

    override fun onStop() {
        super.onStop()
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
