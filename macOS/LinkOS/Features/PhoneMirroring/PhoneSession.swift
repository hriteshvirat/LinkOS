import Foundation
import Combine
import AppKit
import CoreGraphics

@MainActor
final class PhoneSession: ObservableObject {
    static let shared = PhoneSession()
    
    @Published var currentFrame: CGImage? = nil
    @Published var isStreaming = false
    @Published var batteryLevel: Int = 100
    @Published var latencyMs: Double = 0
    @Published var fps: Double = 0
    @Published var isPrivacyModeEnabled = false
    
    private var lastFrameTime = Date()
    private var frameCount = 0
    private var fpsTimer: Timer?
    
    private init() {
        // Calculate FPS periodically
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.fps = Double(self.frameCount)
                self.frameCount = 0
            }
        }
    }
    
    // MARK: - Lifecycle Controls
    
    func startSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Starting Phone Mirroring session", category: .media)
        let payload: [String: Any] = [
            "action": "START_STREAM"
        ]
        await sendControlMessage(payload)
        isStreaming = true
    }
    
    func pauseSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Pausing Phone Mirroring stream", category: .media)
        let payload: [String: Any] = [
            "action": "PAUSE_STREAM"
        ]
        await sendControlMessage(payload)
    }
    
    func resumeSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Resuming Phone Mirroring stream", category: .media)
        let payload: [String: Any] = [
            "action": "RESUME_STREAM"
        ]
        await sendControlMessage(payload)
    }
    
    func stopSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Stopping Phone Mirroring session", category: .media)
        let payload: [String: Any] = [
            "action": "STOP_STREAM"
        ]
        await sendControlMessage(payload)
        isStreaming = false
        currentFrame = nil
    }
    
    func togglePrivacyMode(enabled: Bool) async {
        isPrivacyModeEnabled = enabled
        let payload: [String: Any] = [
            "action": "SET_PRIVACY_MODE",
            "enabled": enabled
        ]
        await sendControlMessage(payload)
    }
    
    // MARK: - Raw Frame Processing
    
    func receiveFrame(_ data: Data) {
        frameCount += 1
        let now = Date()
        let interval = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        
        // Calculate latency as a dynamic metric
        let calcLatency = interval * 1000.0
        self.latencyMs = (self.latencyMs * 0.9) + (calcLatency * 0.1) // Smooth latency jitter
        
        // Decode JPEG frame asynchronously on background queue
        DispatchQueue.global(qos: .userInteractive).async {
            guard let cgDataProvider = CGDataProvider(data: data as CFData),
                  let cgImage = CGImage(
                      jpegDataProviderSource: cgDataProvider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ) else {
                return
            }
            
            DispatchQueue.main.async {
                self.currentFrame = cgImage
            }
        }
    }
    
    // MARK: - Inbound Input Injection Actions
    
    func sendClick(x: Float, y: Float) {
        let payload: [String: Any] = [
            "action": "CLICK",
            "x": x,
            "y": y
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    func sendSwipe(startX: Float, startY: Float, endX: Float, endY: Float, duration: Int) {
        let payload: [String: Any] = [
            "action": "SWIPE",
            "startX": startX,
            "startY": startY,
            "endX": endX,
            "endY": endY,
            "duration": duration
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    func sendText(_ text: String) {
        let payload: [String: Any] = [
            "action": "TEXT",
            "text": text
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    func sendBackspace() {
        let payload: [String: Any] = [
            "action": "BACKSPACE"
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    func sendKey(_ key: String) {
        let payload: [String: Any] = [
            "action": key
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    func sendClipboardImage(_ base64String: String) {
        let payload: [String: Any] = [
            "action": "CLIPBOARD_PASTE_IMAGE",
            "image_base64": base64String
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    func sendLaunchApp(packageName: String) {
        let payload: [String: Any] = [
            "action": "LAUNCH_APP",
            "package_name": packageName
        ]
        Task {
            await sendControlMessage(payload)
        }
    }
    
    // MARK: - Private Transport Helper
    
    private func sendControlMessage(_ payload: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        
        if let connection = await WebSocketServer.shared.activeConnectedDeviceConnection {
            let envelope = MessageRouter.createEvent(channel: "phone", payload: data)
            try? await connection.send(envelope)
        }
    }
}
