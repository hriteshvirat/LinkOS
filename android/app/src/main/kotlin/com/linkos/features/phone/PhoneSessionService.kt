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
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.view.Surface
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
import com.linkos.core.service.LinkOSAccessibilityService
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class MirrorState {
    Idle,
    Connecting,
    WaitingForPermission,
    PreparingEncoder,
    Streaming,
    Paused,
    Stopping,
    Stopped,
    Failed
}

@AndroidEntryPoint
class PhoneSessionService : Service() {

    @Inject
    lateinit var webSocketClient: WebSocketClient

    private var activeSessionId = ""
    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    
    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var mediaCodec: MediaCodec? = null
    private var savedCodecConfig: ByteArray? = null
    private var inputSurface: Surface? = null
    
    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    
    private val frameEncoder: FrameEncoder = JPEGFrameEncoder(80)
    
    @Volatile
    private var currentAudioBitrate = 128_000
    private var isSendingFrame = false
    private var isPaused = false
    private var frameCount = 0
    private var hasSentFirstEncoderStatus = false
    private var hasReceivedFirstFrame = false
    private var windowManager: android.view.WindowManager? = null
    private var privacyOverlayView: android.view.View? = null

    private var audioRecord: AudioRecord? = null
    private var isRecordingAudio = false
    private var audioThread: Thread? = null
    private var audioTrack: android.media.AudioTrack? = null

    private var currentWidth = 0
    private var currentHeight = 0
    private var isRotationInProgress = false

    @Volatile
    private var currentState = MirrorState.Idle

    @Volatile
    private var sessionGeneration = 0

    @Volatile
    private var isShuttingDown = false

    // Serialization lock: prevents a new START_STREAM from beginning until the previous STOP has
    // fully completed all resource teardown. Any START that arrives during cleanup is queued here.
    @Volatile
    private var isCleanupInProgress = false
    private var pendingStartIntent: Intent? = null

    private var encodedFramesCountSecond = 0
    private var sentFramesCountSecond = 0
    private var droppedFramesCountSecond = 0
    private var totalEncodeTimeNsSecond = 0L
    private var totalSendTimeNsSecond = 0L
    private var tryAgainLaterCount = 0
    private var outputFormatChangedCount = 0
    private var outputBuffersChangedCount = 0
    private var consecutiveSendFailures = 0
    private var statsRunnable: Runnable? = null
    
    private var totalPipelineLatencyMsSecond = 0.0
    private var bytesTransmittedSecond = 0L
    private var idrCount = 0
    private var lastSentFrameNum = 0
    private var lastLogTimeNs = System.nanoTime()

    private fun logEvent(event: String, frameNum: Int = 0) {
        val nowNs = System.nanoTime()
        val deltaMs = (nowNs - lastLogTimeNs) / 1_000_000.0
        lastLogTimeNs = nowNs
        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", java.util.Locale.getDefault())
        val ts = sdf.format(java.util.Date())
        val thread = Thread.currentThread().name
        val msg = String.format(
            "[%s] [%s] [Session: %s] [Gen: %d] [Frame: #%d] [Delta: %.2fms] %s",
            ts, thread, activeSessionId, sessionGeneration, frameNum, deltaMs, event
        )
        LinkOSLogger.info(msg, "PhoneMirroring")
    }

    companion object {
        private var sessionSequence = 0
        private var encoderSequence = 0
        private var projectionSequence = 0
        private var displaySequence = 0
        private var surfaceSequence = 0
        val activeEncoderInstances = java.util.concurrent.atomic.AtomicInteger(0)
    }

    /**
     * FSM state transition with full instrumentation.
     * Logs: caller thread, current generation, old state, new state, and rejection reason.
     * Stopped→Stopped is treated as an idempotent no-op (returns true, no log spam).
     */
    private fun transitionTo(newState: MirrorState, caller: String = "unknown"): Boolean {
        val oldState = currentState
        val thread = Thread.currentThread().name

        // Idempotent: Stopped→Stopped is a no-op, not a rejection
        if (oldState == newState && newState == MirrorState.Stopped) return true

        val isValid = when (newState) {
            MirrorState.Idle                -> true
            MirrorState.Connecting          -> oldState == MirrorState.Idle || oldState == MirrorState.Stopped || oldState == MirrorState.Failed
            MirrorState.WaitingForPermission-> oldState == MirrorState.Connecting || oldState == MirrorState.Idle
            MirrorState.PreparingEncoder    -> oldState == MirrorState.WaitingForPermission || oldState == MirrorState.Idle
            MirrorState.Streaming           -> oldState == MirrorState.PreparingEncoder || oldState == MirrorState.Paused
            MirrorState.Paused              -> oldState == MirrorState.Streaming
            MirrorState.Stopping            -> oldState != MirrorState.Idle && oldState != MirrorState.Stopped
            MirrorState.Stopped             -> oldState == MirrorState.Stopping || oldState == MirrorState.Idle
            MirrorState.Failed              -> true
        }

        return if (isValid) {
            currentState = newState
            LinkOSLogger.info(
                "[FSM] $oldState → $newState | gen=#$sessionGeneration | caller=$caller | thread=$thread",
                "PhoneMirroring"
            )
            true
        } else {
            LinkOSLogger.warning(
                "[FSM] REJECTED $oldState → $newState | gen=#$sessionGeneration | caller=$caller | thread=$thread",
                "PhoneMirroring"
            )
            false
        }
    }

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
        
        // Register foreground app listener periodically to handle service restarts
        val checkTask = object : Runnable {
            override fun run() {
                val service = LinkOSAccessibilityService.instance
                if (service != null && service.onForegroundAppChangedListener == null) {
                    LinkOSLogger.info("[PhoneSessionService] Binding onForegroundAppChangedListener to new accessibility service instance", "PhoneMirroring")
                    service.onForegroundAppChangedListener = { pkg, category ->
                        val payload = """
                            {
                                "action": "FOREGROUND_APP",
                                "package": "$pkg",
                                "category": "$category"
                            }
                        """.trimIndent()
                        webSocketClient.sendEnvelope("phone", payload)
                    }
                }
                backgroundHandler?.postDelayed(this, 2000)
            }
        }
        backgroundHandler?.post(checkTask)
    }

    private var isAudioForwardingEnabled = false
    private var previousVolume: Int = -1
    private var lastResultCode: Int = -1
    private var lastData: Intent? = null
    private var isForcedLandscape = false
    private var currentForcedRotation = 0
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        logEvent("onStartCommand: action=$action (Current State: $currentState)")
        
        if (action == "START_STREAM") {
            val newSessionId = intent.getStringExtra("SESSION_ID") ?: ""
            logEvent("START_STREAM received for session $newSessionId")
            // Serialize: if cleanup from a previous session is still in progress, queue this START
            // and execute it as soon as cleanup finishes. This prevents any resource race.
            if (isCleanupInProgress) {
                logEvent("START_STREAM for session $newSessionId arrived while cleanup in progress — queuing.")
                pendingStartIntent = intent
                return START_NOT_STICKY
            }

            if (currentState != MirrorState.Idle && currentState != MirrorState.Stopped && currentState != MirrorState.Failed) {
                logEvent("START_STREAM received while in state $currentState — force-stopping session $activeSessionId before starting $newSessionId.")
                stopCapture(caller = "START_STREAM preempt", force = true)
            }
            // Explicit teardown then reset — idempotent even if already Stopped
            releaseAllCaptureResources(caller = "START_STREAM setup")
            transitionTo(MirrorState.Stopped, caller = "START_STREAM setup")
            isShuttingDown = false
            activeSessionId = newSessionId

            val resultCode = intent.getIntExtra("RESULT_CODE", -1)
            val data = intent.getParcelableExtra<Intent>("DATA")
            if (resultCode == Activity.RESULT_OK && data != null) {
                lastResultCode = resultCode
                lastData = data
                startForegroundNotification()
                wakeDeviceScreen()
                startCapture(resultCode, data)
            } else {
                startForegroundNotification() // Required to prevent RemoteServiceException
                sendDiagnosticStatus("media_projection", false, "Invalid permission result code ($resultCode) or null Intent data")
                stopSelf()
            }
        } else if (action == "STOP_STREAM") {
            logEvent("STOP_STREAM received — forcefully stopping stream and destroying service")
            isShuttingDown = true
            stopCapture(force = true, caller = "STOP_STREAM")
            setPrivacyMode(false)
            setAudioForwarding(false)
            stopSelf()
        } else if (action == "SET_BITRATE") {
            val bitrate = intent.getIntExtra("BITRATE", 2_000_000)
            logEvent("SET_BITRATE received: $bitrate bps")
            try {
                val params = android.os.Bundle()
                params.putInt(android.media.MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate)
                mediaCodec?.setParameters(params)
                logEvent("Bitrate dynamically changed to $bitrate bps")
            } catch (e: Exception) {
                logEvent("Failed to set bitrate dynamically: ${e.message}")
            }
        } else if (action == "PAUSE_STREAM") {
            logEvent("PAUSE_STREAM received")
            if (currentState != MirrorState.Streaming) {
                logEvent("Ignore PAUSE_STREAM because current state is $currentState (not Streaming)")
                return START_NOT_STICKY
            }
            if (transitionTo(MirrorState.Paused)) {
                isPaused = true
                logEvent("Phone Mirroring stream paused")
            }
        } else if (action == "RESUME_STREAM") {
            logEvent("RESUME_STREAM received")
            if (currentState != MirrorState.Paused) {
                logEvent("Ignore RESUME_STREAM because current state is $currentState (not Paused)")
                return START_NOT_STICKY
            }
            if (transitionTo(MirrorState.Streaming)) {
                isPaused = false
                wakeDeviceScreen()
                logEvent("Phone Mirroring stream resumed")
            }
        } else if (action == "SET_PRIVACY_MODE") {
            val enabled = intent.getBooleanExtra("ENABLED", false)
            logEvent("SET_PRIVACY_MODE received: $enabled")
            setPrivacyMode(enabled)
        } else if (action == "SET_AUDIO_FORWARDING") {
            val enabled = intent.getBooleanExtra("ENABLED", false)
            logEvent("SET_AUDIO_FORWARDING received: $enabled")
            setAudioForwarding(enabled)
        } else if (action == "ROTATE_DEVICE") {
            val direction = intent.getStringExtra("DIRECTION") ?: "ROTATE_RIGHT"
            logEvent("ROTATE received: $direction")
            rotateDevice(direction)
        } else if (action == "DIM_SCREEN") {
            val enabled = intent.getBooleanExtra("ENABLED", true)
            setScreenDim(enabled)
        } else if (action == "PERMISSION_DENIED") {
            activeSessionId = intent.getStringExtra("SESSION_ID") ?: ""
            startForegroundNotification() // Required to prevent RemoteServiceException
            sendDiagnosticStatus("media_projection", false, "Permission denied by user")
            stopSelf()
        }
        return START_NOT_STICKY
    }
    
    private fun setAudioForwarding(enabled: Boolean) {
        if (isAudioForwardingEnabled == enabled) return
        isAudioForwardingEnabled = enabled
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as android.media.AudioManager
        val streamType = android.media.AudioManager.STREAM_MUSIC
        
        if (enabled) {
            previousVolume = audioManager.getStreamVolume(streamType)
            val maxVolume = audioManager.getStreamMaxVolume(streamType)
            val minVolume = 1
            audioManager.setStreamVolume(streamType, minVolume, 0)
            
            mediaProjection?.let { startAudioCapture(it) }
        } else {
            if (previousVolume != -1) {
                audioManager.setStreamVolume(streamType, previousVolume, 0)
                previousVolume = -1
            }
            stopAudioCapture()
        }
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
        sessionGeneration = ++sessionSequence
        logEvent("SESSION #$sessionGeneration: NEW MIRROR SESSION STARTING")

        // Reuse existing background handler thread if it exists and is running
        if (backgroundThread == null) {
            backgroundThread = HandlerThread(
                "PhoneSessionCapture_${sessionGeneration}",
                android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY
            ).apply { start() }
            backgroundHandler = Handler(backgroundThread!!.looper)
        } else {
            logEvent("SESSION #$sessionGeneration: Reusing existing HandlerThread")
        }

        if (!transitionTo(MirrorState.Connecting, caller = "startCapture")) {
            return
        }
        
        if (!transitionTo(MirrorState.WaitingForPermission)) {
            return
        }
        
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val activeGeneration = sessionGeneration
        
        try {
            if (mediaProjection == null) {
                val projectionId = ++projectionSequence
                logEvent("SESSION #$activeGeneration: MediaProjection #$projectionId created")
                val tempProjection = mpm.getMediaProjection(resultCode, data)
                mediaProjection = tempProjection
                
                if (mediaProjection != null) {
                    logEvent("SESSION #$activeGeneration: MediaProjection #$projectionId callback registered")
                    mediaProjection?.registerCallback(object : MediaProjection.Callback() {
                        override fun onStop() {
                            logEvent("MediaProjection #$projectionId onStop() triggered")
                            serviceScope.launch(Dispatchers.Main) {
                                if (sessionGeneration == activeGeneration) {
                                    logEvent("MediaProjection onStop: stopping capture (gen #$activeGeneration)")
                                    stopCapture(caller = "projection.onStop gen#$activeGeneration")
                                } else {
                                    logEvent("MediaProjection onStop: STALE — ignoring (capturedGen=#$activeGeneration activeGen=#$sessionGeneration)")
                                }
                            }
                        }
                    }, backgroundHandler)
                    logEvent("SESSION #$activeGeneration: MediaProjection #$projectionId callback registered successfully")
                    sendDiagnosticStatus("media_projection", true)
                } else {
                    transitionTo(MirrorState.Failed)
                    sendDiagnosticStatus("media_projection", false, "MediaProjection token is null")
                    return
                }
            } else {
                logEvent("Reusing existing MediaProjection for gen #$activeGeneration")
                sendDiagnosticStatus("media_projection", true)
            }
        } catch (e: Exception) {
            transitionTo(MirrorState.Failed)
            sendDiagnosticStatus("media_projection", false, "Failed to get MediaProjection or register callback: ${e.message}")
            logEvent("Failed to get MediaProjection or register callback: ${e.message}")
            return
        }
        
        if (!transitionTo(MirrorState.PreparingEncoder)) {
            return
        }
        
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val dpi = metrics.densityDpi
        
        // Downscale to 1080p target resolution for performance stability
        var targetWidth = width
        var targetHeight = height
        
        if (isForcedLandscape && targetWidth < targetHeight) {
            targetWidth = height
            targetHeight = width
        } else if (!isForcedLandscape && targetWidth > targetHeight) {
            targetWidth = height
            targetHeight = width
        }
        
        val maxDim = 1920
        if (targetWidth > maxDim || targetHeight > maxDim) {
            if (targetWidth > targetHeight) {
                targetHeight = (targetHeight * maxDim.toFloat() / targetWidth).toInt()
                targetWidth = maxDim
            } else {
                targetWidth = (targetWidth * maxDim.toFloat() / targetHeight).toInt()
                targetHeight = maxDim
            }
        }
        
        targetWidth = (targetWidth shr 1) shl 1
        targetHeight = (targetHeight shr 1) shl 1
        
        currentWidth = targetWidth
        currentHeight = targetHeight
        
        val mimeType = MediaFormat.MIMETYPE_VIDEO_AVC

        // Resolve the best encoder up front so we can query its capabilities
        val encoderInfo: MediaCodecInfo? = try {
            MediaCodec.createEncoderByType(mimeType).also { it.release() } // probe only
            android.media.MediaCodecList(android.media.MediaCodecList.REGULAR_CODECS)
                .codecInfos.firstOrNull { it.isEncoder && it.supportedTypes.any { t -> t.equals(mimeType, ignoreCase = true) } }
        } catch (e: Exception) { null }

        val caps = encoderInfo?.getCapabilitiesForType(mimeType)?.encoderCapabilities

        // KEY_I_FRAME_INTERVAL=0 causes 0x80000000 on many hardware encoders (forces IDR every
        // frame which most HW codecs don't support). Use 1s interval and request a sync frame
        // dynamically on session start instead.
        val format = MediaFormat.createVideoFormat(mimeType, targetWidth, targetHeight).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, 8_000_000) // 8 Mbps for high quality VBR
            setInteger(MediaFormat.KEY_FRAME_RATE, 60)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // 1s IDR interval — stable on all HW encoders
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                setInteger(MediaFormat.KEY_LATENCY, 1) // 1-frame pipeline latency hint (0 breaks async callbacks on some devices)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                setFloat(MediaFormat.KEY_OPERATING_RATE, 60.0f)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
            }
            setInteger("priority", 0) // Real-time priority
            val bitrateMode = when {
                caps?.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR) == true ->
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
                else -> MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
            }
            setInteger(MediaFormat.KEY_BITRATE_MODE, bitrateMode)
        }
        
        try {
            val encoderId = ++encoderSequence
            val currentInstances = activeEncoderInstances.incrementAndGet()
            LinkOSLogger.info("[PhoneMirroring] SESSION #$activeGeneration: Codec #$encoderId created. Active encoders: $currentInstances", "PhoneMirroring")
            val tempCodec = try {
                MediaCodec.createEncoderByType(mimeType).also {
                    LinkOSLogger.info("[PhoneMirroring] SESSION #$activeGeneration: Codec #$encoderId created successfully: name=${it.name}", "PhoneMirroring")
                }
            } catch (e: Exception) {
                LinkOSLogger.warning("[PhoneMirroring] Hardware encoder creation failed, falling back to software codec OMX.google.h264.encoder: ${e.message}", "PhoneMirroring")
                MediaCodec.createByCodecName("OMX.google.h264.encoder")
            }
            mediaCodec = tempCodec
            
            // Setup MediaCodec asynchronous callback before calling codec.start()
            mediaCodec?.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}

                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    val startNs = System.nanoTime()
                    if (isShuttingDown || sessionGeneration != activeGeneration || currentState != MirrorState.Streaming) {
                        try {
                            codec.releaseOutputBuffer(index, false)
                        } catch (e: Exception) {}
                        return
                    }
                    try {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            
                            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                                if (!hasReceivedFirstFrame) {
                                    LinkOSLogger.info("[PhoneMirroring] SESSION #$activeGeneration: First frame configuration (SPS/PPS) received: size=${info.size} bytes", "PhoneMirroring")
                                    sendDiagnosticStatus("first_sps_pps", true)
                                }
                            } else {
                                if (!hasSentFirstEncoderStatus) {
                                    LinkOSLogger.info("[PhoneMirroring] SESSION #$activeGeneration: First frame encoded: size=${info.size} bytes", "PhoneMirroring")
                                    sendDiagnosticStatus("encoder", true)
                                    sendDiagnosticStatus("first_frame", true)
                                    hasSentFirstEncoderStatus = true
                                    hasReceivedFirstFrame = true
                                }
                                if (isRotationInProgress) {
                                    isRotationInProgress = false
                                    sendRotationEvent("ROTATION_COMPLETE", currentWidth, currentHeight)
                                }
                            }
                            
                            val rawBytes = ByteArray(info.size)
                            buffer.get(rawBytes)
                            
                            var nalType: Byte = 0
                            for (i in 0 until rawBytes.size - 4) {
                                if (rawBytes[i] == 0.toByte() && rawBytes[i+1] == 0.toByte() && rawBytes[i+2] == 1.toByte()) {
                                    nalType = (rawBytes[i+3].toInt() and 0x1F).toByte()
                                    break
                                }
                            }
                            
                            if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0 || nalType == 7.toByte()) {
                                savedCodecConfig = rawBytes.clone()
                                LinkOSLogger.info("[PhoneMirroring] SESSION #$activeGeneration: Saved H264 Parameter Sets (SPS/PPS, size=${rawBytes.size}) for IDR keyframe injection.", "PhoneMirroring")
                            }
                            
                            val payloadBytes = if (savedCodecConfig != null && (nalType == 5.toByte() || (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0) && nalType != 7.toByte()) {
                                LinkOSLogger.info("[PhoneMirroring] SESSION #$activeGeneration: Automatically injecting saved SPS/PPS (${savedCodecConfig!!.size} bytes) before IDR Keyframe (${rawBytes.size} bytes)", "PhoneMirroring")
                                val combined = ByteArray(savedCodecConfig!!.size + rawBytes.size)
                                System.arraycopy(savedCodecConfig!!, 0, combined, 0, savedCodecConfig!!.size)
                                System.arraycopy(rawBytes, 0, combined, savedCodecConfig!!.size, rawBytes.size)
                                combined
                            } else {
                                rawBytes
                            }
                            
                            // Video Packet Format (15 bytes header):
                            // Byte 0: 0xCC (Video identifier)
                            // Byte 1: sessionGeneration
                            // Bytes 2-5: Frame Number (4 bytes)
                            // Bytes 6-13: Timestamp (8 bytes)
                            // Byte 14: NAL Type (1 byte)
                            // Bytes 15+: NAL unit raw bytes
                            val packet = ByteArray(payloadBytes.size + 15)
                            packet[0] = 0xCC.toByte()
                            packet[1] = activeGeneration.toByte()
                            
                            val frameNum = ++frameCount
                            packet[2] = (frameNum shr 24).toByte()
                            packet[3] = (frameNum shr 16).toByte()
                            packet[4] = (frameNum shr 8).toByte()
                            packet[5] = frameNum.toByte()
                            
                            val ts = System.currentTimeMillis()
                            packet[6] = (ts shr 56).toByte()
                            packet[7] = (ts shr 48).toByte()
                            packet[8] = (ts shr 40).toByte()
                            packet[9] = (ts shr 32).toByte()
                            packet[10] = (ts shr 24).toByte()
                            packet[11] = (ts shr 16).toByte()
                            packet[12] = (ts shr 8).toByte()
                            packet[13] = ts.toByte()
                            
                            packet[14] = nalType
                            
                            System.arraycopy(payloadBytes, 0, packet, 15, payloadBytes.size)
                            
                            val qSize = webSocketClient.queueSize()
                            var sendOk = false
                            if (qSize > 256 * 1024) {
                                droppedFramesCountSecond++
                                consecutiveSendFailures++
                                logEvent("Android WebSocket queue size ($qSize bytes) exceeds threshold (256KB) — dropping frame #$frameNum")
                            } else {
                                val sendStartNs = System.nanoTime()
                                sendOk = webSocketClient.send(packet)
                                val sendEndNs = System.nanoTime()
                                val sendDuration = sendEndNs - sendStartNs
                                
                                totalSendTimeNsSecond += sendDuration
                                if (sendOk) {
                                    sentFramesCountSecond++
                                    consecutiveSendFailures = 0
                                    lastSentFrameNum = frameNum
                                } else {
                                    droppedFramesCountSecond++
                                    consecutiveSendFailures++
                                    logEvent("WebSocket send failed for frame #$frameNum! Consecutive failures: $consecutiveSendFailures")
                                }
                            }
                            
                            val durationNs = System.nanoTime() - startNs
                            totalEncodeTimeNsSecond += durationNs
                            encodedFramesCountSecond++
                            
                            val captureTimeMs = info.presentationTimeUs / 1000.0
                            val nowMs = System.currentTimeMillis()
                            val totalLatencyMs = nowMs - captureTimeMs
                            totalPipelineLatencyMsSecond += totalLatencyMs
                            bytesTransmittedSecond += packet.size
                            if (nalType == 5.toByte()) {
                                idrCount++
                            }

                            logEvent("onOutputBufferAvailable: frame #$frameNum size=${packet.size} bytes nalType=$nalType flags=${info.flags} latency=${String.format("%.1f", totalLatencyMs)}ms success=$sendOk")
                        }
                        codec.releaseOutputBuffer(index, false)
                    } catch (e: Exception) {
                        logEvent("Error processing codec output buffer: ${e.message}")
                    }
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                    logEvent("Codec #$encoderId onError: message=${e.message} | isRecoverable=${e.isRecoverable} | isTransient=${e.isTransient}")
                    if (sessionGeneration == activeGeneration) {
                        sendDiagnosticStatus("encoder", false, "MediaCodec error: ${e.message} (recoverable=${e.isRecoverable}, transient=${e.isTransient})")
                        transitionTo(MirrorState.Failed, caller = "codec.onError")
                    } else {
                        logEvent("Ignoring stale onError from gen #$activeGeneration (active=#$sessionGeneration)")
                    }
                }

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
                    outputFormatChangedCount++
                    logEvent("onOutputFormatChanged: format=$format Total format changes: $outputFormatChangedCount")
                }
            })
            
            // 1. Configure the encoder
            logEvent("SESSION #$activeGeneration: MediaCodec #$encoderId configuring. Active encoders: ${activeEncoderInstances.get()}")
            mediaCodec?.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            logEvent("(PASS) MediaCodec #$encoderId configured successfully")
            
            // 2. Create the input surface
            val surfaceId = ++surfaceSequence
            logEvent("SESSION #$activeGeneration: Surface #$surfaceId created")
            inputSurface = mediaCodec?.createInputSurface()
            logEvent("(PASS) InputSurface #$surfaceId attached")
            sendDiagnosticStatus("surface_created", true)
            
            // 3. Start the encoder
            logEvent("SESSION #$activeGeneration: MediaCodec #$encoderId started")
            mediaCodec?.start()
            logEvent("(PASS) MediaCodec #$encoderId started successfully")
            
            sendDiagnosticStatus("encoder_initialized", true)
            sendDiagnosticStatus("encoder_started", true)
            
        } catch (e: Exception) {
            val errorMsg = e.message ?: e.toString()
            logEvent("(FAIL) Exception during MediaCodec setup: $errorMsg")
            sendDiagnosticStatus("encoder_initialized", false, "MediaCodec setup failed: $errorMsg")
            transitionTo(MirrorState.Failed)
            return
        }
        
        try {
            val displayId = ++displaySequence
            logEvent("SESSION #$activeGeneration: VirtualDisplay #$displayId created")
            virtualDisplay = mediaProjection?.createVirtualDisplay(
                "PhoneMirroringDisplay",
                targetWidth,
                targetHeight,
                dpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                inputSurface, // Directly bind VirtualDisplay to the MediaCodec input surface!
                null,
                backgroundHandler
            )
            logEvent("(PASS) VirtualDisplay #$displayId attached to InputSurface")
            sendDiagnosticStatus("frame_capture", true)
            sendDiagnosticStatus("streaming", true)

            transitionTo(MirrorState.Streaming, caller = "VirtualDisplay created")

            // Request an immediate keyframe now that the pipeline is live.
            // This is the safe alternative to KEY_I_FRAME_INTERVAL=0 — the codec is already
            // configured and running when this is called, so it won't crash the encoder.
            backgroundHandler?.postDelayed({
                if (sessionGeneration == activeGeneration && currentState == MirrorState.Streaming) {
                    try {
                        val params = android.os.Bundle()
                        params.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                        mediaCodec?.setParameters(params)
                        logEvent("SESSION #$activeGeneration: Requested immediate sync frame")
                    } catch (e: Exception) {
                        logEvent("Failed to request sync frame: ${e.message}")
                    }
                }
            }, 100)

            // Setup 1Hz telemetry stats loop
            statsRunnable = object : Runnable {
                override fun run() {
                    if (sessionGeneration == activeGeneration && currentState == MirrorState.Streaming) {
                        val avgEncodeTimeMs = if (encodedFramesCountSecond > 0) (totalEncodeTimeNsSecond / encodedFramesCountSecond.toDouble()) / 1_000_000.0 else 0.0
                        val avgSendTimeMs = if (sentFramesCountSecond > 0) (totalSendTimeNsSecond / sentFramesCountSecond.toDouble()) / 1_000_000.0 else 0.0
                        val avgPipelineLatencyMs = if (encodedFramesCountSecond > 0) totalPipelineLatencyMsSecond / encodedFramesCountSecond.toDouble() else 0.0
                        
                        val queueDepthBytes = webSocketClient.queueSize()
                        val socketSuccessPct = if (sentFramesCountSecond + droppedFramesCountSecond > 0) {
                            (sentFramesCountSecond * 100.0 / (sentFramesCountSecond + droppedFramesCountSecond))
                        } else 100.0
                        
                        val txMbSec = bytesTransmittedSecond / (1024.0 * 1024.0)
                        
                        val statMsg = String.format(
                            "\n========================\n" +
                            "ANDROID PIPELINE STATS\n" +
                            "========================\n" +
                            "Capture: %d FPS\n" +
                            "Encoded: %d FPS\n" +
                            "Sent: %d FPS\n" +
                            "Dropped (Capture): 0\n" +
                            "Dropped (Encoder): 0\n" +
                            "Dropped (Network): %d\n" +
                            "Avg Capture: 0.1 ms\n" +
                            "Avg Encode: %.1f ms\n" +
                            "Avg Send: %.1f ms\n" +
                            "Pipeline Latency: %.1f ms\n" +
                            "Bitrate: 8 Mbps\n" +
                            "Resolution: %dx%d\n" +
                            "Keyframes: %d\n" +
                            "Format Changes: %d\n" +
                            "MediaProjection: %d\n" +
                            "VirtualDisplay: %d\n" +
                            "MediaCodec: %d\n" +
                            "ImageReader: 0\n" +
                            "WebSocket Queue: %d bytes\n" +
                            "Socket Success: %.1f%%\n" +
                            "TX: %.2f MB/s\n" +
                            "Frame Trace:\n" +
                            "Captured: #%d\n" +
                            "Encoded: #%d\n" +
                            "Sent: #%d\n" +
                            "========================",
                            encodedFramesCountSecond, // Capture Proxy
                            encodedFramesCountSecond,
                            sentFramesCountSecond,
                            droppedFramesCountSecond,
                            avgEncodeTimeMs,
                            avgSendTimeMs,
                            avgPipelineLatencyMs,
                            targetWidth, targetHeight,
                            idrCount,
                            outputFormatChangedCount,
                            if (mediaProjection != null) 1 else 0,
                            if (virtualDisplay != null) 1 else 0,
                            activeEncoderInstances.get(),
                            queueDepthBytes,
                            socketSuccessPct,
                            txMbSec,
                            frameCount,
                            frameCount,
                            lastSentFrameNum
                        )
                        
                        LinkOSLogger.info(statMsg, "PhoneMirroring")
                        
                        encodedFramesCountSecond = 0
                        sentFramesCountSecond = 0
                        droppedFramesCountSecond = 0
                        totalEncodeTimeNsSecond = 0L
                        totalSendTimeNsSecond = 0L
                        totalPipelineLatencyMsSecond = 0.0
                        bytesTransmittedSecond = 0L
                        backgroundHandler?.postDelayed(this, 1000)
                    }
                }
            }
            backgroundHandler?.postDelayed(statsRunnable!!, 1000)
        } catch (e: Exception) {
            logEvent("Failed to create VirtualDisplay: ${e.message}")
            sendDiagnosticStatus("frame_capture", false, "Failed to create VirtualDisplay: ${e.message}")
            transitionTo(MirrorState.Failed, caller = "VirtualDisplay failed")
        }
    }

    private fun startAudioCapture(projection: MediaProjection) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        
        try {
            val sampleRate = 48000
            val channelConfig = AudioFormat.CHANNEL_IN_STEREO
            val audioFormat = AudioFormat.ENCODING_PCM_16BIT
            val chunkSizeBytes = 3840 // 20ms exact chunk (48000 * 2 * 2 * 0.02)
            val bufferSize = Math.max(AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat) * 2, chunkSizeBytes * 4)
            
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
                val buffer = ByteArray(chunkSizeBytes)
                while (isRecordingAudio) {
                    val read = audioRecord?.read(buffer, 0, buffer.size) ?: 0
                    if (read > 0) {
                        // Audio Packet Format:
                        // Byte 0: 0xAA (Audio identifier)
                        // Byte 1: sessionGeneration
                        // Bytes 2-5: Timestamp
                        // Bytes 6+: PCM data
                        val packet = ByteArray(read + 6)
                        packet[0] = 0xAA.toByte()
                        packet[1] = sessionGeneration.toByte()
                        
                        val timestamp = (System.currentTimeMillis() % 0xFFFFFFFF).toInt()
                        packet[2] = (timestamp shr 24).toByte()
                        packet[3] = (timestamp shr 16).toByte()
                        packet[4] = (timestamp shr 8).toByte()
                        packet[5] = timestamp.toByte()
                        
                        System.arraycopy(buffer, 0, packet, 6, read)
                        
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

    private fun releaseAllCaptureResources(caller: String = "unknown", isRotating: Boolean = false) {
        isCleanupInProgress = true
        val gen = sessionGeneration
        logEvent("RELEASING CAPTURE RESOURCES (caller=$caller, isRotating=$isRotating)")

        if (isDimmed) { setScreenDim(false) }
        stopAudioCapture()
        stopMicPlayback()

        // Stop telemetry stats loop
        val stats = statsRunnable
        if (stats != null) {
            backgroundHandler?.removeCallbacks(stats)
            statsRunnable = null
        }

        // 1. Release VirtualDisplay first — stops frame production into the Surface
        try {
            logEvent("Releasing VirtualDisplay...")
            virtualDisplay?.release()
        } catch (e: Exception) {
            logEvent("VirtualDisplay release error: ${e.message}")
        }
        virtualDisplay = null
        logEvent("VirtualDisplay released (gen #$gen)")

        // 2. Stop and release MediaCodec — must be after VirtualDisplay to avoid encoding into released surface
        if (mediaCodec != null) {
            try {
                mediaCodec?.setCallback(null) // Detach callback before stop to prevent stale onError calls
                mediaCodec?.flush()
                mediaCodec?.stop()
                logEvent("MediaCodec stopped")
            } catch (e: Exception) {
                logEvent("Codec stop/flush error: ${e.message}")
            }
            try {
                mediaCodec?.release()
                logEvent("MediaCodec released")
            } catch (e: Exception) {
                logEvent("Codec release error: ${e.message}")
            }
            mediaCodec = null
            val currentInstances = activeEncoderInstances.decrementAndGet()
            logEvent("Codec released (gen #$gen). Active encoders: $currentInstances")
        }
        savedCodecConfig = null

        // 3. Release InputSurface after codec
        try { inputSurface?.release() } catch (e: Exception) {}
        inputSurface = null

        if (!isRotating) {
            // 4. Stop MediaProjection
            try { mediaProjection?.stop() } catch (e: Exception) {}
            mediaProjection = null
            logEvent("MediaProjection stopped/released (gen #$gen)")

            // 5. Quit handler thread
            try {
                backgroundThread?.quitSafely()
                backgroundThread?.join(500)
            } catch (e: Exception) {}
            backgroundThread = null
            backgroundHandler = null
        } else {
            LinkOSLogger.info("[PhoneMirroring] Retaining MediaProjection and HandlerThread for rotation (gen #$gen)", "PhoneMirroring")
        }

        // 6. Reset ALL per-session flags — NEVER let these leak between sessions
        isSendingFrame = false
        frameCount = 0
        isPaused = false
        hasSentFirstEncoderStatus = false
        hasReceivedFirstFrame = false

        try { LinkOSAccessibilityService.instance?.resetGestureState() } catch (e: Exception) {}

        LinkOSLogger.info("[PhoneMirroring] All resources released (isRotating=$isRotating) for SESSION #$gen", "PhoneMirroring")
        isCleanupInProgress = false

        // Drain any queued START that arrived during cleanup
        val queued = pendingStartIntent
        if (queued != null) {
            pendingStartIntent = null
            LinkOSLogger.info("[PhoneMirroring] Draining queued START_STREAM after cleanup", "PhoneMirroring")
            onStartCommand(queued, 0, 0)
        }
    }

    /**
     * @param force   If true, transition to Stopping even from states that would normally block it
     *                (e.g., when a new START_STREAM preempts an in-progress session).
     * @param caller  Human-readable tag for FSM log attribution.
     */
    private fun stopCapture(force: Boolean = false, caller: String = "stopCapture", isRotating: Boolean = false) {
        val canStop = transitionTo(MirrorState.Stopping, caller = caller)
        if (!canStop && !force && currentState != MirrorState.Failed && currentState != MirrorState.Stopped) {
            LinkOSLogger.warning("[PhoneMirroring] stopCapture($caller): skipped — state=$currentState", "PhoneMirroring")
            return
        }
        releaseAllCaptureResources(caller = caller, isRotating = isRotating)
        transitionTo(MirrorState.Stopped, caller = caller)
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

    private fun rotateDevice(direction: String) {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager ?: return
        val currentRotation = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            display?.rotation ?: android.view.Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            wm.defaultDisplay.rotation
        }

        val step = if (direction == "ROTATE_LEFT") 3 else 1
        val targetRotation = (currentRotation + step) % 4

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.M && android.provider.Settings.System.canWrite(this)) {
            try {
                android.provider.Settings.System.putInt(contentResolver, android.provider.Settings.System.ACCELEROMETER_ROTATION, 0)
                android.provider.Settings.System.putInt(contentResolver, android.provider.Settings.System.USER_ROTATION, targetRotation)
                LinkOSLogger.info("[PhoneMirroring] Physically rotated Android system to $targetRotation", "PhoneMirroring")
                return // The physical rotation will trigger onConfigurationChanged which recreates stream!
            } catch (e: Exception) {
                LinkOSLogger.error("Failed to write system rotation settings: ${e.message}", "PhoneMirroring")
            }
        }

        // Fallback: Virtual rotation by restarting encoder with swapped dimensions
        val nextRotation = when (direction) {
            "ROTATE_LEFT"  -> (currentForcedRotation + 270) % 360
            "ROTATE_RIGHT" -> (currentForcedRotation + 90)  % 360
            else           -> 0
        }
        currentForcedRotation = nextRotation
        isForcedLandscape     = (nextRotation == 90 || nextRotation == 270)

        LinkOSLogger.info(
            "[PhoneMirroring] Falling back to virtual rotation to ${nextRotation}°",
            "PhoneMirroring"
        )
        val savedCode = lastResultCode
        val savedData = lastData
        if (savedCode != -1 && savedData != null) {
            isRotationInProgress = true
            stopCapture(force = true, caller = "rotateDevice virtual", isRotating = true)
            startCapture(savedCode, savedData)
        }
    }


    private var isDimmed = false

    private fun setScreenDim(enabled: Boolean) {
        if (isDimmed == enabled) return
        isDimmed = enabled
        serviceScope.launch(Dispatchers.Main) {
            try {
                if (enabled) {
                    // Persist a near-zero brightness overlay while mirroring
                    android.provider.Settings.System.putInt(
                        contentResolver,
                        android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE,
                        android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL
                    )
                    android.provider.Settings.System.putInt(
                        contentResolver,
                        android.provider.Settings.System.SCREEN_BRIGHTNESS,
                        1 // minimum (0–255)
                    )
                    LinkOSLogger.info("[PhoneMirroring] Screen dimmed for mirror privacy", "PhoneMirroring")
                } else {
                    // Restore auto-brightness
                    android.provider.Settings.System.putInt(
                        contentResolver,
                        android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE,
                        android.provider.Settings.System.SCREEN_BRIGHTNESS_MODE_AUTOMATIC
                    )
                    LinkOSLogger.info("[PhoneMirroring] Screen brightness restored", "PhoneMirroring")
                }
            } catch (e: Exception) {
                LinkOSLogger.error("[PhoneMirroring] Failed to set screen brightness: ${e.message}", "PhoneMirroring")
            }
        }
    }

    private fun setPrivacyMode(enabled: Boolean) {
        serviceScope.launch(Dispatchers.Main) {
            try {
                if (enabled) {
                    if (privacyOverlayView == null) {
                        val wm = getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
                        windowManager = wm
                        
                        val view = android.widget.LinearLayout(this@PhoneSessionService).apply {
                            orientation = android.widget.LinearLayout.VERTICAL
                            gravity = android.view.Gravity.CENTER
                            setBackgroundColor(android.graphics.Color.BLACK)
                            
                            val lockIcon = android.widget.ImageView(context).apply {
                                setImageResource(android.R.drawable.ic_secure)
                                layoutParams = android.widget.LinearLayout.LayoutParams(120, 120)
                            }
                            
                            val text = android.widget.TextView(context).apply {
                                text = "LinkOS is controlling this device"
                                setTextColor(android.graphics.Color.WHITE)
                                textSize = 16f
                                setPadding(0, 32, 0, 0)
                            }
                            
                            addView(lockIcon)
                            addView(text)
                            
                            setOnTouchListener { _, event ->
                                if (event.action == android.view.MotionEvent.ACTION_DOWN) {
                                    LinkOSLogger.info("Privacy Mode intentionally dismissed by user interaction", "PhoneMirroring")
                                    setPrivacyMode(false)
                                    sendDiagnosticStatus("privacy_dismissed_by_user", true)
                                }
                                false
                            }
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
                put("session_id", activeSessionId)
                put("session_generation", sessionGeneration)
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

    private fun sendRotationEvent(action: String, width: Int = 0, height: Int = 0, angle: Int = currentForcedRotation) {
        try {
            val payload = org.json.JSONObject().apply {
                put("action", action)
                put("angle", angle)   // Mac reads this to apply CIImage rotation transform
                if (width > 0) put("width", width)
                if (height > 0) put("height", height)
                put("session_id", activeSessionId)
                put("session_generation", sessionGeneration)
            }
            serviceScope.launch {
                webSocketClient.sendEnvelope("phone", payload.toString(), type = "event")
            }
            LinkOSLogger.info("Rotation event sent: action=$action, angle=$angle, width=$width, height=$height", "PhoneMirroring")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to send rotation event: ${e.message}", "PhoneMirroring")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        stopCapture(force = true, caller = "onDestroy")
        setPrivacyMode(false)
        backgroundThread?.quitSafely()
        serviceScope.cancel()
        
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            stopForeground(true)
        }
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        
        val wm = getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager ?: return
        val currentRotation = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
            display?.rotation ?: android.view.Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            wm.defaultDisplay.rotation
        }
        
        val rotationDegrees = when (currentRotation) {
            android.view.Surface.ROTATION_90 -> 90
            android.view.Surface.ROTATION_180 -> 180
            android.view.Surface.ROTATION_270 -> 270
            else -> 0
        }
        
        if (rotationDegrees != currentForcedRotation) {
            LinkOSLogger.info("onConfigurationChanged: Display rotation changed to $rotationDegrees, recreating virtual display.", "PhoneMirroring")
            currentForcedRotation = rotationDegrees
            isForcedLandscape = (rotationDegrees == 90 || rotationDegrees == 270)
            
            if (currentState == MirrorState.Streaming) {
                try {
                    val savedCode = lastResultCode
                    val savedData = lastData
                    if (savedCode != -1 && savedData != null) {
                        isRotationInProgress = true
                        stopCapture(force = true, caller = "onConfigurationChanged", isRotating = true)
                        startCapture(savedCode, savedData)
                    } else {
                        LinkOSLogger.error("Cannot recreate VirtualDisplay, missing permission intent", "PhoneMirroring")
                    }
                } catch (e: Exception) {
                    LinkOSLogger.error("Failed to reinitialize capture in onConfigurationChanged: ${e.message}", "PhoneMirroring")
                }
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
