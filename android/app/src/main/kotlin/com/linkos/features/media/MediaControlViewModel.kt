package com.linkos.features.media

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.linkos.core.network.ConnectionStateManager
import com.linkos.core.network.MessageChannel
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import javax.inject.Inject

data class MediaTrackInfo(
    val title: String = "LinkOS Cyberpunk Synth",
    val artist: String = "Antigravity Audio",
    val album: String = "Zero Latency Vol. 1",
    val isPlaying: Boolean = true,
    val volume: Float = 0.75f,
    val brightness: Float = 0.80f
)

@HiltViewModel
class MediaControlViewModel @Inject constructor(
    private val connectionStateManager: ConnectionStateManager
) : ViewModel() {

    private val _mediaInfo = MutableStateFlow(MediaTrackInfo())
    val mediaInfo: StateFlow<MediaTrackInfo> = _mediaInfo.asStateFlow()

    fun sendMediaAction(action: String, value: Int? = null) {
        val payload = JSONObject().apply {
            put("action", action)
            if (value != null) {
                put("value", value)
            }
        }.toString()
        
        viewModelScope.launch {
            connectionStateManager.routeMessage(
                channel = MessageChannel.MEDIA_CONTROL,
                payload = payload.toByteArray(Charsets.UTF_8),
                fromDeviceId = "android_peer"
            )
        }
    }

    fun playPause() {
        _mediaInfo.value = _mediaInfo.value.copy(isPlaying = !_mediaInfo.value.isPlaying)
        sendMediaAction("play_pause")
    }

    fun nextTrack() = sendMediaAction("next")
    fun previousTrack() = sendMediaAction("previous")
    fun volumeUp() = sendMediaAction("volume_up")
    fun volumeDown() = sendMediaAction("volume_down")
    
    fun setVolume(volume: Float) {
        _mediaInfo.value = _mediaInfo.value.copy(volume = volume)
        sendMediaAction("volume", (volume * 100).toInt())
    }

    fun setBrightness(brightness: Float) {
        _mediaInfo.value = _mediaInfo.value.copy(brightness = brightness)
        sendMediaAction("brightness", (brightness * 100).toInt())
    }

    fun toggleMute(muted: Boolean) = sendMediaAction(if (muted) "mute" else "unmute")

    fun triggerAction(action: String) {
        when (action) {
            "play_pause" -> playPause()
            "next" -> nextTrack()
            "previous" -> previousTrack()
            "volume_up" -> volumeUp()
            "volume_down" -> volumeDown()
            else -> sendMediaAction(action)
        }
    }
}
