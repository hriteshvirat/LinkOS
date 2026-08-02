package com.linkos.features.phone

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.linkos.R
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.WebSocketClient
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import javax.inject.Inject

@AndroidEntryPoint
class PhoneSessionService : Service() {

    @Inject
    lateinit var webSocketClient: WebSocketClient

    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    
    private val frameEncoder: FrameEncoder = JPEGFrameEncoder(80)
    
    @Volatile
    private var isSendingFrame = false
    private var isPaused = false
    private var hasSentFirstEncoderStatus = false
    private var hasReceivedFirstFrame = false
    private var windowManager: android.view.WindowManager? = null
    private var privacyOverlayView: android.view.View? = null

    private var audioRecord: AudioRecord? = null
    private var isRecordingAudio = false
    private var audioThread: Thread? = null
    private var audioTrack: android.media.AudioTrack? = null

    override fun onCreate() {
        super.onCreate()
        backgroundThread = HandlerThread("PhoneSessionCaptureThread").apply { start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
        
        serviceScope.launch {
            webSocketClient.messageFlow.collect { bytes ->
                if (bytes.isNotEmpty() && bytes[0] == 0xBB.toByte()) {
                    playbackMicAudio(bytes)
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        LinkOSLogger.info("[PhoneMirroring] (PASS) PhoneSessionService onStartCommand: action=$action", "PhoneMirroring")
        if (action == "START_STREAM") {
            val resultCode = intent.getIntExtra("RESULT_CODE", -1)
            val data = intent.getParcelableExtra<Intent>("DATA")
            if (resultCode == Activity.RESULT_OK && data != null) {
                startForegroundNotification()
                wakeDeviceScreen()
                startCapture(resultCode, data)
            } else {
                stopSelf()
            }
        } else if (action == "STOP_STREAM") {
            stopCapture()
            setPrivacyMode(false)
            stopSelf()
        } else if (action == "PAUSE_STREAM") {
            isPaused = true
            LinkOSLogger.info("Phone Mirroring stream paused", "PhoneMirroring")
        } else if (action == "RESUME_STREAM") {
            isPaused = false
            wakeDeviceScreen()
            LinkOSLogger.info("Phone Mirroring stream resumed", "PhoneMirroring")
        } else if (action == "SET_PRIVACY_MODE") {
            val enabled = intent.getBooleanExtra("ENABLED", false)
            setPrivacyMode(enabled)
        }
        return START_NOT_STICKY
    }

    private fun startForegroundNotification() {
        val channelId = "phone_mirroring_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Phone Mirroring",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
        
        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Phone Mirroring Active")
            .setContentText("LinkOS is mirroring this phone to your Mac")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
            
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1042, notification, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(1042, notification)
        }
        LinkOSLogger.info("[PhoneMirroring] (PASS) Foreground notification created and startForeground called", "PhoneMirroring")
    }

    private fun startCapture(resultCode: Int, data: Intent) {
        hasSentFirstEncoderStatus = false
        hasReceivedFirstFrame = false
        LinkOSLogger.info("[PhoneMirroring] (PASS) startCapture called inside PhoneSessionService", "PhoneMirroring")
        
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        try {
            mediaProjection = mpm.getMediaProjection(resultCode, data)
            if (mediaProjection != null) {
                LinkOSLogger.info("[PhoneMirroring] (PASS) MediaProjection token obtained successfully from resultCode/data", "PhoneMirroring")
                sendDiagnosticStatus("media_projection", true)
            } else {
                sendDiagnosticStatus("media_projection", false, "MediaProjection token is null")
                return
            }
        } catch (e: Exception) {
            sendDiagnosticStatus("media_projection", false, "Failed to get MediaProjection: ${e.message}")
            LinkOSLogger.error("[PhoneMirroring] (FAIL) Failed to get MediaProjection: ${e.message}", "PhoneMirroring")
            return
        }
        
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val dpi = metrics.densityDpi
        
        // Downscale to 1080p target resolution for performance stability
        var targetWidth = width
        var targetHeight = height
        val maxDim = 1080
        if (targetWidth > maxDim || targetHeight > maxDim) {
            if (targetWidth > targetHeight) {
                targetHeight = (targetHeight * maxDim.toFloat() / targetWidth).toInt()
                targetWidth = maxDim
            } else {
                targetWidth = (targetWidth * maxDim.toFloat() / targetHeight).toInt()
                targetHeight = maxDim
            }
        }
        
        try {
            imageReader = ImageReader.newInstance(targetWidth, targetHeight, PixelFormat.RGBA_8888, 2)
            
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                "PhoneMirroringDisplay",
                targetWidth,
                targetHeight,
                dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader?.surface,
                null,
                backgroundHandler
            )
            
            if (virtualDisplay != null) {
                LinkOSLogger.info("[PhoneMirroring] (PASS) VirtualDisplay created successfully: width=$targetWidth, height=$targetHeight, dpi=$dpi", "PhoneMirroring")
                sendDiagnosticStatus("frame_capture", true)
            } else {
                sendDiagnosticStatus("frame_capture", false, "VirtualDisplay is null")
            }
        } catch (e: Exception) {
            sendDiagnosticStatus("frame_capture", false, "Failed to build capture components: ${e.message}")
            LinkOSLogger.error("[PhoneMirroring] (FAIL) Failed to build capture components: ${e.message}", "PhoneMirroring")
            return
        }
        
        imageReader?.setOnImageAvailableListener({ reader ->
            if (isPaused) {
                reader.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            
            if (isSendingFrame) {
                reader.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            if (!hasReceivedFirstFrame) {
                LinkOSLogger.info("[PhoneMirroring] (PASS) ImageReader received first frame image!", "PhoneMirroring")
                hasReceivedFirstFrame = true
            }
            isSendingFrame = true
            
            serviceScope.launch {
                try {
                    val plane = image.planes[0]
                    val buffer = plane.buffer
                    val pixelStride = plane.pixelStride
                    val rowStride = plane.rowStride
                    val rowPadding = rowStride - pixelStride * image.width
                    
                    val bitmap = Bitmap.createBitmap(
                        image.width + rowPadding / pixelStride,
                        image.height,
                        Bitmap.Config.ARGB_8888
                    )
                    bitmap.copyPixelsFromBuffer(buffer)
                    image.close()
                    
                    val croppedBitmap = Bitmap.createBitmap(bitmap, 0, 0, image.width, image.height)
                    val jpegBytes = frameEncoder.encode(croppedBitmap)
                    
                    if (jpegBytes != null) {
                        if (!hasSentFirstEncoderStatus) {
                            LinkOSLogger.info("[PhoneMirroring] (PASS) Frame #1 successfully encoded: size=${jpegBytes.size} bytes", "PhoneMirroring")
                            sendDiagnosticStatus("encoder", true)
                            hasSentFirstEncoderStatus = true
                        }
                        webSocketClient.send(jpegBytes)
                        if (hasSentFirstEncoderStatus && jpegBytes.size > 0 && hasReceivedFirstFrame) {
                            // Print log only once for Frame #1
                            LinkOSLogger.info("[PhoneMirroring] (PASS) Frame #1 sent over raw WebSocket", "PhoneMirroring")
                        }
                    } else {
                        if (!hasSentFirstEncoderStatus) {
                            LinkOSLogger.error("[PhoneMirroring] (FAIL) Frame encoder returned null/failed on first frame", "PhoneMirroring")
                            sendDiagnosticStatus("encoder", false, "Frame encoder returned null bytes")
                        }
                    }
                } catch (e: Exception) {
                    LinkOSLogger.error("Failed to process phone mirror frame: ${e.message}", "PhoneMirroring")
                    image.close()
                } finally {
                    isSendingFrame = false
                }
            }
        }, backgroundHandler)
        
        mediaProjection?.let {
            startAudioCapture(it)
        }
    }

    private fun startAudioCapture(projection: MediaProjection) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        
        try {
            val sampleRate = 44100
            val channelConfig = AudioFormat.CHANNEL_IN_STEREO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val bufferSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat) * 2
            
            val captureConfig = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
                
            val format = AudioFormat.Builder()
                .setEncoding(audioFormat)
                .setSampleRate(sampleRate)
                .setChannelMask(channelConfig)
                .build()
                
            audioRecord = AudioRecord.Builder()
                .setAudioPlaybackCaptureConfig(captureConfig)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferSize)
                .build()
                
            audioRecord?.startRecording()
            isRecordingAudio = true
            
            audioThread = Thread {
                val buffer = ByteArray(1024)
                while (isRecordingAudio) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                    if (read > 0) {
                        val packet = ByteArray(5 + read)
                        packet[0] = 0xAA.toByte()
                        val time = System.currentTimeMillis()
                        packet[1] = (time shr 24).toByte()
                        packet[2] = (time shr 16).toByte()
                        packet[3] = (time shr 8).toByte()
                        packet[4] = time.toByte()
                        System.arraycopy(buffer, 0, packet, 5, read)
                        
                        webSocketClient.send(packet)
                    }
                }
            }
            audioThread?.start()
            LinkOSLogger.info("Audio capture started successfully", "PhoneMirroring")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to start system audio capture: ${e.message}", "PhoneMirroring")
        }
    }

    private fun stopAudioCapture() {
        isRecordingAudio = false
        try {
            audioRecord?.stop()
            audioRecord?.release()
        } catch (e: Exception) {
            // ignore
        }
        audioRecord = null
        audioThread = null
    }

    private fun playbackMicAudio(bytes: ByteArray) {
        try {
            if (audioTrack == null) {
                val sampleRate = 44100
                val channelConfig = AudioFormat.CHANNEL_OUT_MONO
                val audioFormat = AudioFormat.ENCODING_PCM_16BIT
                val bufferSize = android.media.AudioTrack.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                
                audioTrack = android.media.AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(audioFormat)
                            .setSampleRate(sampleRate)
                            .setChannelMask(channelConfig)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(android.media.AudioTrack.MODE_STREAM)
                    .build()
                    
                audioTrack?.play()
            }
            
            audioTrack?.write(bytes, 1, bytes.size - 1)
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to play mic audio: ${e.message}", "PhoneMirroring")
        }
    }

    private fun stopMicPlayback() {
        try {
            audioTrack?.stop()
            audioTrack?.release()
        } catch (e: Exception) {
            // ignore
        }
        audioTrack = null
    }

    private fun stopCapture() {
        stopAudioCapture()
        stopMicPlayback()
        virtualDisplay?.release()
        virtualDisplay = null
        imageReader?.close()
        imageReader = null
        mediaProjection?.stop()
        mediaProjection = null
    }

    private fun wakeDeviceScreen() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            if (!powerManager.isInteractive) {
                @Suppress("DEPRECATION")
                val wakeLock = powerManager.newWakeLock(
                    android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "LinkOS:PhoneWakeLock"
                )
                wakeLock.acquire(3000)
                wakeLock.release()
                LinkOSLogger.info("Device screen wake-up requested", "PhoneMirroring")
            }
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to wake device screen: ${e.message}", "PhoneMirroring")
        }
    }

    private fun setPrivacyMode(enabled: Boolean) {
        serviceScope.launch(Dispatchers.Main) {
            try {
                if (enabled) {
                    if (privacyOverlayView == null) {
                        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
                        windowManager = wm
                        
                        val view = android.view.View(this@PhoneSessionService).apply {
                            setBackgroundColor(android.graphics.Color.BLACK)
                        }
                        
                        val params = android.view.WindowManager.LayoutParams(
                            android.view.WindowManager.LayoutParams.MATCH_PARENT,
                            android.view.WindowManager.LayoutParams.MATCH_PARENT,
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                android.view.WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                            } else {
                                @Suppress("DEPRECATION")
                                android.view.WindowManager.LayoutParams.TYPE_PHONE
                            },
                            android.view.WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                            android.view.WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                            android.view.WindowManager.LayoutParams.FLAG_FULLSCREEN,
                            PixelFormat.TRANSLUCENT
                        )
                        params.screenBrightness = 0.01f
                        
                        wm.addView(view, params)
                        privacyOverlayView = view
                        LinkOSLogger.info("Privacy Mode screen overlay added", "PhoneMirroring")
                    }
                } else {
                    privacyOverlayView?.let { view ->
                        windowManager?.removeView(view)
                        privacyOverlayView = null
                        LinkOSLogger.info("Privacy Mode screen overlay removed", "PhoneMirroring")
                    }
                }
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to update Privacy Mode overlay: ${e.message}", "PhoneMirroring")
            }
        }
    }

    private fun sendDiagnosticStatus(stage: String, ok: Boolean, error: String? = null) {
        try {
            val payload = org.json.JSONObject().apply {
                put("action", "diagnostic_status")
                put("stage", stage)
                put("ok", ok)
                if (error != null) {
                    put("error", error)
                }
            }
            serviceScope.launch {
                webSocketClient.sendEnvelope("phone", payload.toString(), type = "event")
            }
            LinkOSLogger.info("Diagnostic status updated: stage=$stage, ok=$ok, error=$error", "PhoneMirroring")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to send diagnostic status: ${e.message}", "PhoneMirroring")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCapture()
        setPrivacyMode(false)
        backgroundThread?.quitSafely()
        serviceScope.cancel()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
