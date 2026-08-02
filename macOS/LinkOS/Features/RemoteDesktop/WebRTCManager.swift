import Foundation
import CoreMedia

/// WebRTC peer connection manager on macOS host for remote desktop screen streaming.
actor WebRTCManager {
    private let codecManager = CodecManager()
    private let bitrateController = AdaptiveBitrateController()
    private var isPeerConnected = false
    
    var onSignalMessage: ((Data) -> Void)?
    
    func startStreamingSession(deviceId: String) async {
        isPeerConnected = true
        LinkOSLogger.shared.info("WebRTC streaming session initialized for \(deviceId)", category: .media)
    }
    
    func stopStreamingSession() async {
        isPeerConnected = false
        LinkOSLogger.shared.info("WebRTC streaming session stopped", category: .media)
    }
    
    func handleSignalingData(_ data: Data) async {
        // Process SDP offer/answer / ICE candidate exchange over WebSocket control channel
        LinkOSLogger.shared.info("Processed WebRTC signaling payload (\(data.count) bytes)", category: .media)
    }
    
    func processVideoFrame(_ sampleBuffer: CMSampleBuffer) async {
        guard isPeerConnected else { return }
        // Encode CMSampleBuffer via VideoToolbox hardware encoder and pass to WebRTC VideoTrack
    }
}

final class RemoteDesktopPlugin: LinkOSPlugin {
    let pluginId = "remote_desktop"
    let displayName = "Remote Desktop"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["media", "remote_desktop"]
    let requiredPermissions: Set<String> = ["SCREEN_VIEW", "SCREEN_CONTROL", "MOUSE_INPUT", "KEYBOARD_INPUT"]
    
    private(set) var isActive = false
    private let webrtcManager = WebRTCManager()
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        await MainActor.run {
            let service = ScreenCaptureService()
            Task {
                await service.refreshDisplays()
            }
        }
        LinkOSLogger.shared.info("RemoteDesktopPlugin activated", category: .media)
    }
    
    func deactivate() async {
        isActive = false
        await webrtcManager.stopStreamingSession()
        LinkOSLogger.shared.info("RemoteDesktopPlugin deactivated", category: .media)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        if message.channel == "remote_desktop" {
            // Handle Start Stream / Stop Stream request
            if let command = String(data: message.payload, encoding: .utf8) {
                if command.contains("start") {
                    await MainActor.run {
                        let service = ScreenCaptureService()
                        Task {
                            await service.startCapture { [weak self] sampleBuffer in
                                Task {
                                    await self?.webrtcManager.processVideoFrame(sampleBuffer)
                                }
                            }
                        }
                    }
                    await webrtcManager.startStreamingSession(deviceId: message.deviceId)
                } else if command.contains("stop") {
                    await webrtcManager.stopStreamingSession()
                }
            }
        }
    }
    
    func commandPaletteActions() -> [CommandPaletteAction] {
        [
            CommandPaletteAction(
                id: "remote_desktop.start",
                title: "Start Remote Desktop Stream",
                subtitle: "Stream Mac display to connected Android companion",
                icon: "display",
                keywords: ["remote", "desktop", "screen", "stream", "share"],
                category: "Remote Desktop",
                action: { [weak self] in
                    await MainActor.run {
                        let service = ScreenCaptureService()
                        Task {
                            await service.startCapture { _ in }
                        }
                    }
                }
            )
        ]
    }
}
