import Foundation
import Combine
import AppKit
import CoreGraphics
import Vision

enum PhoneConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

@MainActor
final class PhoneSession: ObservableObject {
    static let shared = PhoneSession()
    
    @Published var currentFrame: CGImage? = nil
    @Published var isStreaming = false
    @Published var batteryLevel: Int = 100
    @Published var latencyMs: Double = 0
    @Published var fps: Double = 0
    @Published var isPrivacyModeEnabled = false
    @Published var callState: String = "IDLE"
    @Published var incomingCallNumber: String = ""
    @Published var connectionState: PhoneConnectionState = .disconnected
    
    // Diagnostics State
    @Published var connectionStatus: Bool = false
    @Published var mediaProjectionStatus: Bool = false
    @Published var frameCaptureStatus: Bool = false
    @Published var encoderStatus: Bool = false
    @Published var networkStatus: Bool = false
    @Published var decoderStatus: Bool = false
    @Published var rendererStatus: Bool = false
    @Published var diagnosticsTimeoutReached: Bool = false
    @Published var lastErrorMessage: String = ""
    
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
    
    func setReconnecting() {
        guard connectionState == .connected else { return }
        connectionState = .reconnecting
        LinkOSLogger.shared.info("[PhoneSession] Connection standby - seeking reconnect", category: .media)
    }
    
    func setConnected() {
        connectionState = .connected
        LinkOSLogger.shared.info("[PhoneSession] Connection established", category: .media)
        Task {
            await resumeSession()
        }
    }
    
    func resetDiagnostics() {
        connectionStatus = (connectionState == .connected)
        mediaProjectionStatus = false
        frameCaptureStatus = false
        encoderStatus = false
        networkStatus = false
        decoderStatus = false
        rendererStatus = false
        diagnosticsTimeoutReached = false
        lastErrorMessage = ""
    }
    
    func updateDiagnostic(stage: String, ok: Bool, error: String) {
        switch stage {
        case "media_projection":
            mediaProjectionStatus = ok
        case "frame_capture":
            frameCaptureStatus = ok
        case "encoder":
            encoderStatus = ok
        default:
            break
        }
        if !ok {
            lastErrorMessage = error
            LinkOSLogger.shared.error("[PhoneSession] Stage \(stage) failed: \(error)", category: .media)
        } else {
            LinkOSLogger.shared.info("[PhoneSession] Stage \(stage) completed successfully", category: .media)
        }
    }
    
    // MARK: - Lifecycle Controls
    
    func startSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Starting Phone Mirroring session", category: .media)
        resetDiagnostics()
        let payload: [String: Any] = [
            "action": "START_STREAM"
        ]
        await sendControlMessage(payload)
        isStreaming = true
        connectionState = .connected
        await PhoneAudioService.shared.startPlayback()
    }
    
    func pauseSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Pausing Phone Mirroring stream", category: .media)
        let payload: [String: Any] = [
            "action": "PAUSE_STREAM"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.stopPlayback()
    }
    
    func resumeSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Resuming Phone Mirroring stream", category: .media)
        let payload: [String: Any] = [
            "action": "RESUME_STREAM"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.startPlayback()
    }
    
    func stopSession() async {
        LinkOSLogger.shared.info("[PhoneSession] Stopping Phone Mirroring session", category: .media)
        let payload: [String: Any] = [
            "action": "STOP_STREAM"
        ]
        await sendControlMessage(payload)
        isStreaming = false
        currentFrame = nil
        connectionState = .disconnected
        await PhoneAudioService.shared.stopPlayback()
        await PhoneAudioService.shared.stopMicCapture()
    }
    
    func togglePrivacyMode(enabled: Bool) async {
        isPrivacyModeEnabled = enabled
        let payload: [String: Any] = [
            "action": "SET_PRIVACY_MODE",
            "enabled": enabled
        ]
        await sendControlMessage(payload)
    }

    // MARK: - Telecom Call Actions

    func acceptCall() async {
        let payload: [String: Any] = [
            "action": "CALL_ANSWER"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.startMicCapture()
    }
    
    func rejectCall() async {
        let payload: [String: Any] = [
            "action": "CALL_REJECT"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.stopMicCapture()
    }
    
    func endCall() async {
        let payload: [String: Any] = [
            "action": "CALL_END"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.stopMicCapture()
    }
    
    func transferCallToHandset() async {
        let payload: [String: Any] = [
            "action": "CALL_HANDOFF"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.stopMicCapture()
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
        
        // Mark network connection payload received
        if !networkStatus {
            DispatchQueue.main.async {
                self.networkStatus = true
            }
        }
        
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
                if !self.decoderStatus {
                    self.decoderStatus = true
                }
                self.currentFrame = cgImage
                if !self.rendererStatus {
                    self.rendererStatus = true
                }
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
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        await ConnectionStateManager.shared.routeMessage(channel: .phone, payload: data, from: DeviceIdentity.deviceId)
    }

    // MARK: - AI Agent Screen Context API

    func getPhoneContext() async -> String {
        guard let cgImage = currentFrame else {
            return "No active phone screen mirrored."
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "Failed to perform text recognition on phone screen.")
                    return
                }
                
                let recognizedStrings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                
                let fullText = recognizedStrings.joined(separator: "\n")
                if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(returning: "No visible text detected on phone screen.")
                } else {
                    continuation.resume(returning: fullText)
                }
            }
            
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "Failed to perform text recognition: \(error.localizedDescription)")
            }
        }
    }
}
