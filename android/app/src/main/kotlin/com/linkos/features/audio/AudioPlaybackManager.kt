package com.linkos.features.audio

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.util.Base64
import com.linkos.core.logging.LinkOSLogger
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.ConnectionStateSubscriber
import com.linkos.core.network.MessageChannel
import com.linkos.core.network.QoSState
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AudioPlaybackManager @Inject constructor(
    private val connectionStateManager: ConnectionStateManager
) : ConnectionStateSubscriber {

    override val subscriberId = "audio_playback_manager"
    
    private var audioTrack: AudioTrack? = null
    private var isPlaying = false
    private var isMuted = false
    private var systemVolume = 1.0f
    
    // Playback sync anchors
    private var lastReceivedAudioTimeMs = 0L
    private var totalSamplesPlayed = 0L

    init {
        connectionStateManager.subscribe(this)
    }

    fun startPlayback() {
        if (isPlaying) return
        
        val bufferSize = AudioTrack.getMinBufferSize(
            44100,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_FLOAT
        )
        
        try {
            audioTrack = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                            .setSampleRate(44100)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                AudioTrack(
                    AudioManager.STREAM_MUSIC,
                    44100,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_FLOAT,
                    bufferSize,
                    AudioTrack.MODE_STREAM
                )
            }
            
            audioTrack?.play()
            isPlaying = true
            LinkOSLogger.info("Audio track initialized and playing stream", "AudioSync")
        } catch (e: Exception) {
            LinkOSLogger.error("Failed to initialize AudioTrack: ${e.message}", "AudioSync")
        }
    }

    fun stopPlayback() {
        if (!isPlaying) return
        isPlaying = false
        try {
            audioTrack?.stop()
            audioTrack?.release()
            audioTrack = null
            LinkOSLogger.info("Audio track released", "AudioSync")
        } catch (e: Exception) {
            // Ignore
        }
    }

    fun setMute(muted: Boolean) {
        this.isMuted = muted
        updateTrackVolume()
    }

    fun setVolume(vol: Float) {
        this.systemVolume = vol.coerceIn(0.0f, 1.0f)
        updateTrackVolume()
    }

    private fun updateTrackVolume() {
        val targetVol = if (isMuted) 0.0f else systemVolume
        audioTrack?.setVolume(targetVol)
    }

    override suspend fun onMessageReceived(channel: MessageChannel, payload: ByteArray, fromDeviceId: String) {
        if (channel != MessageChannel.AUDIO || !isPlaying) return
        
        try {
            val text = String(payload, Charsets.UTF_8)
            val json = JSONObject(text)
            
            val timestampMs = json.optLong("timestamp_ms")
            val base64Data = json.optString("data")
            
            val audioBytes = Base64.decode(base64Data, Base64.DEFAULT)
            val floatBuffer = ByteBuffer.wrap(audioBytes)
                .order(ByteOrder.LITTLE_ENDIAN)
                .asFloatBuffer()
                
            val floats = FloatArray(floatBuffer.remaining())
            floatBuffer.get(floats)
            
            // Render audio block to AudioTrack stream
            audioTrack?.write(floats, 0, floats.size, AudioTrack.WRITE_NON_BLOCKING)
            
            lastReceivedAudioTimeMs = timestampMs
            totalSamplesPlayed += floats.size
        } catch (e: Exception) {
            LinkOSLogger.error("Error playing back audio payload: ${e.message}", "AudioSync")
        }
    }

    override suspend fun onQoSChanged(state: QoSState) {
        // Drop audio quality / adjust buffer boundaries on network changes
        if (state.profile == com.linkos.core.network.QoSProfile.DEGRADED) {
            audioTrack?.setPlaybackRate(40000) // Slightly pitch down to prevent underruns
        } else {
            audioTrack?.setPlaybackRate(44100)
        }
    }
}
