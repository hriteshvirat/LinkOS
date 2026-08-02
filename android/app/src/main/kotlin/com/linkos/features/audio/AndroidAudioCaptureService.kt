package com.linkos.features.audio

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.util.Base64
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AndroidAudioCaptureService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val connectionStateManager: ConnectionStateManager
) : ConnectionStateSubscriber {

    override val subscriberId = "android_audio_capture_service"

    private val sampleRate = 44100
    private val channelConfigIn = AudioFormat.CHANNEL_IN_MONO
    private val channelConfigOut = AudioFormat.CHANNEL_OUT_MONO
    private val audioFormat = AudioFormat.ENCODING_PCM_FLOAT // Match macOS float PCM format
    private val bufferSizeIn = AudioRecord.getMinBufferSize(sampleRate, channelConfigIn, audioFormat)
    private val bufferSizeOut = AudioTrack.getMinBufferSize(sampleRate, channelConfigOut, audioFormat)

    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var echoCanceler: AcousticEchoCanceler? = null
    private var noiseSuppressor: NoiseSuppressor? = null

    private var isRecording = false
    private var captureJob: Job? = null
    private val scope = CoroutineScope(Dispatchers.Default)

    private val _isAudioStreaming = MutableStateFlow(false)
    val isAudioStreaming: StateFlow<Boolean> = _isAudioStreaming.asStateFlow()

    init {
        connectionStateManager.subscribe(this)
        setupAudioTrack()
    }

    @SuppressLint("MissingPermission")
    fun startStreaming() {
        if (isRecording) return
        
        try {
            audioRecord = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                channelConfigIn,
                audioFormat,
                bufferSizeIn
            )

            if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
                LinkOSLogger.error("Failed to initialize AudioRecord", "Audio")
                return
            }

            // Enable Native hardware acoustic echo cancellation if supported by the device
            val sessionId = audioRecord?.audioSessionId ?: -1
            if (sessionId != -1) {
                if (AcousticEchoCanceler.isAvailable()) {
                    echoCanceler = AcousticEchoCanceler.create(sessionId)?.apply {
                        enabled = true
                    }
                    LinkOSLogger.info("Acoustic Echo Canceler enabled successfully", "Audio")
                }
                if (NoiseSuppressor.isAvailable()) {
                    noiseSuppressor = NoiseSuppressor.create(sessionId)?.apply {
                        enabled = true
                    }
                    LinkOSLogger.info("Noise Suppressor enabled successfully", "Audio")
                }
            }

            audioRecord?.startRecording()
            isRecording = true
            _isAudioStreaming.value = true

            // Read Loop
            captureJob = scope.launch {
                val floatBuffer = FloatArray(1024)
                while (isRecording) {
                    val readResult = audioRecord?.read(floatBuffer, 0, floatBuffer.size, AudioRecord.READ_BLOCKING) ?: -1
                    if (readResult > 0) {
                        // Convert float array to bytes for transmission
                        val byteBuffer = ByteBuffer.allocate(readResult * 4).order(ByteOrder.LITTLE_ENDIAN)
                        for (i in 0 until readResult) {
                            byteBuffer.putFloat(floatBuffer[i])
                        }
                        
                        val base64Data = Base64.encodeToString(byteBuffer.array(), Base64.NO_WRAP)
                        val payload = JSONObject().apply {
                            put("timestamp_ms", System.currentTimeMillis())
                            put("data", base64Data)
                        }
                        
                        connectionStateManager.routeMessage(
                            channel = MessageChannel.AUDIO,
                            payload = payload.toString().toByteArray(Charsets.UTF_8),
                            fromDeviceId = "android_peer"
                        )
                    }
                }
            }
            LinkOSLogger.info("Started streaming Android audio", "Audio")
        } catch (e: Exception) {
            LinkOSLogger.error("Error starting Android audio stream: ${e.message}", "Audio")
        }
    }

    fun stopStreaming() {
        if (!isRecording) return
        isRecording = false
        captureJob?.cancel()
        captureJob = null
        
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        
        echoCanceler?.release()
        echoCanceler = null
        
        noiseSuppressor?.release()
        noiseSuppressor = null
        
        _isAudioStreaming.value = false
        LinkOSLogger.info("Stopped streaming Android audio", "Audio")
    }

    private fun setupAudioTrack() {
        try {
            audioTrack = AudioTrack.Builder()
                .setAudioAttributes(
                    android.media.AudioAttributes.Builder()
                        .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                        .setContentType(android.media.AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build()
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(audioFormat)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelConfigOut)
                        .build()
                )
                .setBufferSizeInBytes(bufferSizeOut)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()

            audioTrack?.play()
            LinkOSLogger.info("AudioTrack player initialized", "Audio")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to initialize AudioTrack: ${e.message}", "Audio")
        }
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.AUDIO) return
        
        try {
            val text = String(payload, Charsets.UTF_8)
            val json = JSONObject(text)
            
            // Only play audio frames received from remote Mac
            if (fromDeviceId == "android_peer") return
            
            val base64Data = json.optString("data", "")
            if (base64Data.isNotEmpty()) {
                val rawBytes = Base64.decode(base64Data, Base64.NO_WRAP)
                // Convert bytes to float array for AudioTrack playback
                val floatBuffer = FloatArray(rawBytes.size / 4)
                ByteBuffer.wrap(rawBytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(floatBuffer)
                
                audioTrack?.write(floatBuffer, 0, floatBuffer.size, AudioTrack.WRITE_BLOCKING)
            }
        } catch (e: Exception) {
            // Ignore
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {}
}
