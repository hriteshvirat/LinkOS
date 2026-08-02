package com.linkos.features.camera

import androidx.camera.view.PreviewView
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject
import com.linkos.features.files.AndroidFileHandler
import android.graphics.Bitmap
import kotlinx.coroutines.withContext

@HiltViewModel
class CameraViewModel @Inject constructor(
    @dagger.hilt.android.qualifiers.ApplicationContext private val context: android.content.Context,
    private val cameraSyncService: CameraSyncService,
    private val connectionStateManager: ConnectionStateManager,
    private val androidFileHandler: AndroidFileHandler
) : ViewModel(), ConnectionStateSubscriber {

    override val subscriberId = "camera_view_model"

    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming.asStateFlow()

    private val _isFlashEnabled = MutableStateFlow(false)
    val isFlashEnabled: StateFlow<Boolean> = _isFlashEnabled.asStateFlow()

    // Trigger local state for UI reactions
    private val _lensFacing = MutableStateFlow("rear")
    val lensFacing: StateFlow<String> = _lensFacing.asStateFlow()

    private var activeLifecycleOwner: LifecycleOwner? = null
    private var activePreviewView: PreviewView? = null

    init {
        connectionStateManager.subscribe(this)
    }

    override fun onCleared() {
        super.onCleared()
        connectionStateManager.unsubscribe(subscriberId)
        stopCamera()
    }

    fun startCamera(lifecycleOwner: LifecycleOwner, previewView: PreviewView? = null) {
        activeLifecycleOwner = lifecycleOwner
        activePreviewView = previewView
        cameraSyncService.startCameraStream(lifecycleOwner, previewView)
        _isStreaming.value = true
    }

    fun stopCamera() {
        cameraSyncService.stopCameraStream()
        _isStreaming.value = false
        activeLifecycleOwner = null
        activePreviewView = null
    }

    fun switchCamera(lifecycleOwner: LifecycleOwner) {
        cameraSyncService.switchCamera(lifecycleOwner, activePreviewView)
        _lensFacing.value = if (_lensFacing.value == "rear") "front" else "rear"
    }

    fun toggleFlash(enabled: Boolean) {
        cameraSyncService.toggleFlash(enabled)
        _isFlashEnabled.value = enabled
    }

    override suspend fun onConnectionPhaseChanged(phase: com.linkos.core.network.ConnectionPhase, device: com.linkos.core.network.PeerDevice?) {
        if (phase == com.linkos.core.network.ConnectionPhase.DISCONNECTED) {
            viewModelScope.launch {
                stopCamera()
            }
        } else if (phase == com.linkos.core.network.ConnectionPhase.CONNECTED) {
            viewModelScope.launch {
                activeLifecycleOwner?.let { owner ->
                    activePreviewView?.let { view ->
                        startCamera(owner, view)
                    }
                }
            }
        }
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.CAMERA) return
        try {
            val text = String(payload, Charsets.UTF_8)
            val json = JSONObject(text)
            val action = json.optString("action")
            
            LinkOSLogger.info("CameraViewModel received remote command: $action", "CameraSync")
            
            when (action) {
                "toggle_flash" -> {
                    val enabled = json.optBoolean("enabled", false)
                    viewModelScope.launch {
                        toggleFlash(enabled)
                    }
                }
                "switch_lens" -> {
                    viewModelScope.launch {
                        activeLifecycleOwner?.let {
                            switchCamera(it)
                        }
                    }
                }
                "zoom" -> {
                    val ratio = json.optDouble("ratio", 1.0).toFloat()
                    viewModelScope.launch {
                        cameraSyncService.setZoom(ratio)
                    }
                }
                "stop_camera" -> {
                    viewModelScope.launch {
                        stopCamera()
                    }
                }
                "capture_image" -> {
                    viewModelScope.launch {
                        cameraSyncService.capturePhoto { bitmap ->
                            viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                                try {
                                    val downloadDir = java.io.File(
                                        android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),
                                        "LinkOS"
                                    )
                                    if (!downloadDir.exists()) {
                                        downloadDir.mkdirs()
                                    }
                                    val finalFile = java.io.File(downloadDir, "clicked_pic_${System.currentTimeMillis()}.jpg")
                                    val out = java.io.FileOutputStream(finalFile)
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
                                    out.close()
                                    
                                    // Trigger background-safe success haptics
                                    com.linkos.ui.components.HapticUtils.success(context)
                                    
                                    // Scan media file
                                    android.media.MediaScannerConnection.scanFile(
                                        context,
                                        arrayOf(finalFile.absolutePath),
                                        null
                                    ) { _, _ -> }
                                    
                                    // Show a status bar notification
                                    val channelId = "linkos_camera_channel"
                                    val notificationManager = context.getSystemService(android.content.Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
                                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                                        val chan = android.app.NotificationChannel(channelId, "LinkOS Camera", android.app.NotificationManager.IMPORTANCE_DEFAULT)
                                        notificationManager.createNotificationChannel(chan)
                                    }
                                    val builder = androidx.core.app.NotificationCompat.Builder(context, channelId)
                                        .setContentTitle("Photo Captured")
                                        .setContentText("Saved to Downloads/LinkOS")
                                        .setSmallIcon(com.linkos.R.drawable.ic_notification)
                                        .setAutoCancel(true)
                                    notificationManager.notify(8811, builder.build())
                                    
                                    // Notify local UI/Toast
                                    withContext(kotlinx.coroutines.Dispatchers.Main) {
                                        android.widget.Toast.makeText(context, "✓ Photo saved to Downloads/LinkOS", android.widget.Toast.LENGTH_SHORT).show()
                                    }
                                    
                                    // Upload to Mac
                                    androidFileHandler.uploadFileToMac(finalFile.absolutePath, fromDeviceId)
                                } catch (e: Exception) {
                                    LinkOSLogger.error("Failed to capture photo: ${e.message}", "CameraSync")
                                }
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to parse camera command: ${e.message}", "CameraSync")
        }
    }

    fun captureImage() {
        viewModelScope.launch {
            val payload = JSONObject().apply {
                put("action", "capture_image")
            }.toString()
            cameraSyncService.sendControlMessage(payload)
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {}
}
