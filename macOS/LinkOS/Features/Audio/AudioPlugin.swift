import Foundation

final class AudioPlugin: LinkOSPlugin {
    let pluginId = "audio"
    let displayName = "Audio Continuity"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["audio"]
    let requiredPermissions: Set<String> = ["AUDIO_RECORD", "AUDIO_PLAYBACK"]
    
    private(set) var isActive = false
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        await AudioSyncService.shared.startStreaming()
        LinkOSLogger.shared.info("[Audio] Audio Continuity plugin activated", category: .media)
    }
    
    func deactivate() async {
        isActive = false
        await AudioSyncService.shared.stopStreaming()
        LinkOSLogger.shared.info("[Audio] Audio Continuity plugin deactivated", category: .media)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        guard isActive else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
               let base64Data = json["data"] as? String,
               let pcmData = Data(base64Encoded: base64Data) {
                // Play chunk on Main thread
                await AudioSyncService.shared.playReceivedAudioChunk(data: pcmData)
            }
        } catch {
            LinkOSLogger.shared.error("[Audio] Failed to parse incoming Android audio frame: \(error.localizedDescription)", category: .media)
        }
    }
    
    func commandPaletteActions() -> [CommandPaletteAction] {
        [
            CommandPaletteAction(
                id: "audio.mute",
                title: "Mute Audio Sync",
                subtitle: "Temporarily mute active audio stream",
                icon: "speaker.slash",
                keywords: ["audio", "mute", "sound"],
                category: "Audio",
                action: {
                    Task { @MainActor in
                        AudioSyncService.shared.setMute(true)
                    }
                }
            ),
            CommandPaletteAction(
                id: "audio.unmute",
                title: "Unmute Audio Sync",
                subtitle: "Resume active audio loopback stream",
                icon: "speaker.wave.2",
                keywords: ["audio", "unmute", "sound", "volume"],
                category: "Audio",
                action: {
                    Task { @MainActor in
                        AudioSyncService.shared.setMute(false)
                    }
                }
            )
        ]
    }
}
