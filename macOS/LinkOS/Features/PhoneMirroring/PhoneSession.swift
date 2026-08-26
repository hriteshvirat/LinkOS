import Foundation
import Combine
import AppKit
import CoreGraphics
import Vision
import VideoToolbox
import CoreMedia
import UserNotifications

struct FramePipelineMetrics: Sendable {
    var captureTs: Date
    var encodeTs: Date
    var networkRxTs: Date
    var decodeTs: Date
}

enum PhoneConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

enum DiagnosticStageStatus: Equatable {
    case pending
    case success
    case failure(String)
    case inProgress(String)
}

class PixelBufferWrapper: @unchecked Sendable {
    static var outstandingCount: Int = 0
    let buffer: CVPixelBuffer
    let frameNum: UInt32
    init(_ buffer: CVPixelBuffer, frameNum: UInt32) {
        self.buffer = buffer
        self.frameNum = frameNum
        PixelBufferWrapper.outstandingCount += 1
    }
    deinit {
        PixelBufferWrapper.outstandingCount -= 1
    }
}

class SampleBufferWrapper: @unchecked Sendable {
    static var outstandingCount: Int = 0
    let buffer: CMSampleBuffer
    let frameNum: UInt32
    init(_ buffer: CMSampleBuffer, frameNum: UInt32) {
        self.buffer = buffer
        self.frameNum = frameNum
        SampleBufferWrapper.outstandingCount += 1
    }
    deinit {
        SampleBufferWrapper.outstandingCount -= 1
    }
}


enum PhoneMirrorState: String {
    case disconnected
    case connecting
    case receivingStream
    case decoderReady
    case presenting
    case streaming
    case paused
    case stopping
    case stopped
    case error
}

@MainActor
final class PhoneSession: ObservableObject {
    @Published var mirrorState: PhoneMirrorState = .disconnected
    @Published var displayRotation: Int = 0 // Valid orientations: 0, 90, 180, 270 degrees
    @Published var isRotating: Bool = false  // Suppresses reconnect during encoder teardown/restart for rotation
    
    // Strict Ownership: Managed exclusively by PhoneSessionManager
    
    @Published var sessionId: String = UUID().uuidString
    var onSampleBufferReady: ((CMSampleBuffer) -> Void)?
    var onPixelBufferReady: ((PixelBufferWrapper) -> Void)?
    var isSessionAlive: Bool = false
    var decodedFrameCount: Int = 0
    private var hasShownSuccessNotification: Bool = false

    var latestPixelBuffer: PixelBufferWrapper? = nil
    
    // Kept for backward compatibility, updated only when explicitly requested
    @Published var currentFrame: CGImage? = nil
    @Published var isStreaming = false
    @Published var batteryLevel: Int = 100
    @Published var latencyMs: Double = 0
    @Published var fps: Double = 0
    @Published var currentBitrateKbps: Double = 5000.0
    @Published var isPrivacyModeEnabled = false
    @Published var tapLocation: CGPoint? = nil
    @Published var tapTrigger: Int = 0
    
    // Subsystem Latency Metrics
    var latencyCaptureEncode: Double = 0
    var latencyEncodeNetwork: Double = 0
    var latencyNetworkDecode: Double = 0
    var latencyDecodePresent: Double = 0
    @Published var latencyTotal: Double = 0
    @Published var callState: String = "IDLE"
    @Published var incomingCallNumber: String = ""
    @Published var connectionState: PhoneConnectionState = .disconnected
    @Published var activeAppCategory: String = "unknown"

    @Published var expectedSessionGeneration: UInt8 = 0
    @Published var isPaused: Bool = false
    @Published var activeAppPackage: String = ""

    
    // Unified 6-Stage Diagnostics State (Single Source of Truth)
    @Published var connectionStatus: DiagnosticStageStatus = .pending
    @Published var mediaProjectionStatus: DiagnosticStageStatus = .pending
    @Published var frameCaptureStatus: DiagnosticStageStatus = .pending
    @Published var encoderStatus: DiagnosticStageStatus = .pending
    @Published var networkStatus: DiagnosticStageStatus = .pending
    @Published var decoderStatus: DiagnosticStageStatus = .pending
    @Published var rendererStatus: DiagnosticStageStatus = .pending
    
    @Published var watchdogDump: String = ""
    @Published var diagnosticsTimeoutReached: Bool = false
    @Published var lastErrorMessage: String = ""
    
    private var lastFrameTime = Date()
    private var frameCount = 0
    private var fpsTimer: Timer?
    private var watchdogTimer: Timer?
    let h264Decoder = H264Decoder()

    // Instrumentation
    @Published var decodedFPS: Double = 0
    @Published var displayedFPS: Double = 0
    var decodedFrameCountSecond: Int = 0
    var displayedFrameCountSecond: Int = 0
    var droppedFramesSecond: Int = 0

    // Phase 2: Decoder backpressure — drop incoming frames when decoder is busy
    private var isDecoderBusy: Bool = false

    // Phase 3: Cached frame dimensions — avoid MainActor dispatch on every decoded frame
    private var lastKnownWidth: Int = 0
    private var lastKnownHeight: Int = 0
    private var hasDecoderSucceededOnce: Bool = false
    private var hasReceivedFirstFrame: Bool = false

    // Phase 6: Latency accumulator — smooth on the 1Hz timer, not on every frame
    private var rawIntervalAccumulator: Double = 0
    private var rawIntervalCount: Int = 0

    private var lastKnownSize: CGSize? = nil
    
    init() {
        // 1Hz stats timer: batch all UI publishing here, never per-frame
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Read counters on current thread (they are non-@Published plain Ints)
            let decoded = self.decodedFrameCountSecond
            let displayed = self.displayedFrameCountSecond
            let dropped = self.droppedFramesSecond
            let frames = self.frameCount
            // Phase 6: compute smoothed latency from accumulated interval data
            let smoothedLatency: Double
            if self.rawIntervalCount > 0 {
                let avgInterval = self.rawIntervalAccumulator / Double(self.rawIntervalCount)
                smoothedLatency = (self.latencyMs * 0.7) + (avgInterval * 1000.0 * 0.3)
            } else {
                smoothedLatency = self.latencyMs
            }
            self.rawIntervalAccumulator = 0
            self.rawIntervalCount = 0
            self.decodedFrameCountSecond = 0
            self.displayedFrameCountSecond = 0
            self.droppedFramesSecond = 0
            self.frameCount = 0

            let outstandingPbs = PixelBufferWrapper.outstandingCount
            let outstandingSbs = SampleBufferWrapper.outstandingCount
            let trace = PipelineTracker.shared.getTraceString()
            LinkOSLogger.shared.info("[PIPELINE STATS] Decoded: \(decoded) FPS | Rendered: \(displayed) FPS | Dropped: \(dropped) | PBs: \(outstandingPbs) | SBs: \(outstandingSbs) | Trace: \(trace)", category: .media)

            // Phase 5: Adaptive quality controller
            self.adaptQuality(decodedFPS: decoded, droppedFrames: dropped)

            Task { @MainActor in
                self.fps = Double(frames)
                self.decodedFPS = Double(decoded)
                self.displayedFPS = Double(displayed)
                self.latencyMs = smoothedLatency
            }
        }
        
        h264Decoder.onDecoderInitialized = { [weak self] in
            guard let self = self else { return }
            Task { @MainActor in
                if case .failure = self.decoderStatus {} else {
                    self.decoderStatus = .inProgress("Decoder Ready")
                }
            }
        }
        
        h264Decoder.onDecoderError = { [weak self] errMsg in
            guard let self = self else { return }
            Task { @MainActor in
                self.decoderStatus = .failure(errMsg)
                self.lastErrorMessage = errMsg
            }
        }
        
        h264Decoder.onPixelBufferDecoded = { [weak self] pixelBufferWrapper in
            guard let self = self else { return }

            // Phase 2: Release backpressure lock immediately on decode completion
            self.isDecoderBusy = false

            // Full pipeline trace: log decoder callback arrival
            let sessionObjId = ObjectIdentifier(self)
            LinkOSLogger.shared.info("[Pipeline] Decoder callback: frame #\(pixelBufferWrapper.frameNum) for session [\(sessionObjId)]", category: .media)

            // Send pixel buffer to renderer — no MainActor hop needed
            if self.onPixelBufferReady != nil {
                LinkOSLogger.shared.info("[Pipeline] onPixelBufferReady: frame #\(pixelBufferWrapper.frameNum) -> calling on session [\(sessionObjId)]", category: .media)
                self.onPixelBufferReady?(pixelBufferWrapper)
            } else {
                LinkOSLogger.shared.error("[Pipeline] onPixelBufferReady is NIL for frame #\(pixelBufferWrapper.frameNum) - frame dropped! Session [\(sessionObjId)] (ID: \(self.sessionId))", category: .media)
            }

            // Phase 3: Increment counters on decode thread (plain Ints, no @Published churn)
            self.decodedFrameCount += 1
            self.decodedFrameCountSecond += 1
            self.latestPixelBuffer = pixelBufferWrapper

            // Invalidate watchdog without main thread hop
            DispatchQueue.main.async { [weak self] in
                self?.watchdogTimer?.invalidate()
                self?.watchdogTimer = nil
            }

            // Phase 3: First-frame one-time actions (only dispatch to MainActor once)
            if !self.hasDecoderSucceededOnce {
                self.hasDecoderSucceededOnce = true
                LinkOSLogger.shared.info("[PhoneSession] (PASS) Frame #1 successfully decoded and presented on Mac", category: .media)
                Task { @MainActor in
                    self.decoderStatus = .success
                    self.rendererStatus = .success
                    if self.mirrorState != .presenting && self.mirrorState != .streaming {
                        _ = self.transitionTo(.presenting)
                        self.isStreaming = true
                    }
                    self.showMirroringSuccessNotification()
                }
            }

            // Phase 3: Dimension change detection — only dispatch to MainActor when dimensions change
            let w = CVPixelBufferGetWidth(pixelBufferWrapper.buffer)
            let h = CVPixelBufferGetHeight(pixelBufferWrapper.buffer)
            if w != self.lastKnownWidth || h != self.lastKnownHeight {
                self.lastKnownWidth = w
                self.lastKnownHeight = h
                Task { @MainActor in
                    let effW = (self.displayRotation == 90 || self.displayRotation == 270) ? CGFloat(h) : CGFloat(w)
                    let effH = (self.displayRotation == 90 || self.displayRotation == 270) ? CGFloat(w) : CGFloat(h)
                    let newSize = CGSize(width: effW, height: effH)
                    if self.isRotating {
                        self.isRotating = false
                        LinkOSLogger.shared.info("[PhoneSession] First frame after rotation received, animating window to \(Int(effW))x\(Int(effH))", category: .media)
                        PhoneWindowController.shared.animateAspectRatioChange(newSize)
                        self.lastKnownSize = newSize
                    } else if self.lastKnownSize != newSize && w > 0 && h > 0 {
                        LinkOSLogger.shared.info("[PhoneSession] Resolution changed to \(Int(effW))x\(Int(effH)), updating window aspect ratio", category: .media)
                        PhoneWindowController.shared.updateAspectRatio(newSize)
                        self.lastKnownSize = newSize
                    }
                }
            }
        }
    }
    
    func triggerTapAnimation(at location: CGPoint, in viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0, !viewSize.width.isNaN, !viewSize.height.isNaN else { return }
        let swiftUIX = location.x
        let swiftUIY = location.y
        self.tapLocation = CGPoint(x: swiftUIX / viewSize.width, y: swiftUIY / viewSize.height)
        self.tapTrigger += 1
    }
    
    func setReconnecting() {
        guard connectionState == .connected else { return }
        guard !isRotating else {
            LinkOSLogger.shared.info("[PhoneSession] Suppressing reconnect: rotation in progress", category: .media)
            return
        }
        connectionState = .reconnecting
        LinkOSLogger.shared.info("[PhoneSession] Connection standby - seeking reconnect", category: .media)
    }
    
    func setConnected(source: String) {
        // Secondary guard: never auto-resume if the user explicitly stopped mirroring.
        // This catches any call path that bypasses the PhoneMirroringPlugin guard.
        guard !PhoneSessionManager.shared.userStoppedMirroring else {
            LinkOSLogger.shared.info("[PhoneSession] setConnected(\(source)) blocked — userStoppedMirroring is true.", category: .media)
            return
        }
        guard connectionState != .connected else {
            LinkOSLogger.shared.info("[PhoneSession] Connection established ignored (already connected) from source: \(source)", category: .media)
            return
        }
        connectionState = .connected
        LinkOSLogger.shared.info("[PhoneSession] Connection established from source: \(source)", category: .media)
        Task {
            await resumeSession()
        }
    }
    
    func resetDiagnostics() {
        connectionStatus = (connectionState == .connected) ? .success : .pending
        mediaProjectionStatus = .pending
        frameCaptureStatus = .pending
        encoderStatus = .pending
        networkStatus = .pending
        decoderStatus = .pending
        rendererStatus = .pending
        diagnosticsTimeoutReached = false
        lastErrorMessage = ""
    }
    
    func updateDiagnostic(stage: String, ok: Bool, error: String) {
        let status: DiagnosticStageStatus = ok ? .success : .failure(error)
        switch stage {
        case "media_projection":
            mediaProjectionStatus = status
        case "frame_capture", "virtual_display":
            frameCaptureStatus = status
        case "encoder", "encoder_started", "encoder_initialized", "first_frame":
            if ok {
                if encoderStatus != .success {
                    encoderStatus = .success
                    startDecoderWatchdogIfNeeded()
                }
            } else {
                encoderStatus = .failure(error)
            }
        case "first_sps_pps":
            if ok {
                if networkStatus != .success {
                    networkStatus = .inProgress("SPS/PPS Received")
                }
            } else {
                networkStatus = .failure(error)
            }
        case "network":
            networkStatus = status
        case "decoder":
            decoderStatus = status
        case "renderer":
            rendererStatus = status
        default:
            break
        }
    }
    
    private func startDecoderWatchdogIfNeeded() {
        guard watchdogTimer == nil, decoderStatus != .success else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.decoderStatus != .success && self.encoderStatus == .success {
                    let dump = self.h264Decoder.getWatchdogDump()
                    self.watchdogDump = dump
                    LinkOSLogger.shared.error("[PhoneSession] Decoder Watchdog Triggered after 4s! Dump:\n\(dump)", category: .media)
                }
            }
        }
    }
    
    @discardableResult
    func transitionTo(_ newState: PhoneMirrorState) -> Bool {
        let oldState = self.mirrorState
        guard oldState != newState else { return true }
        self.mirrorState = newState
        
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let timeString = df.string(from: Date())
        
        LinkOSLogger.shared.info("[PhoneSession] State Transition: \(oldState.rawValue) -> \(newState.rawValue) at \(timeString)", category: .media)
        NotificationCenter.default.post(name: NSNotification.Name("PhoneMirrorStateChanged"), object: nil)
        return true
    }
    
    // MARK: - Lifecycle Controls
    
    func startSession() async {
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneSession] startSession called on session [\(ObjectIdentifier(self))] (ID: \(self.sessionId)). Stack Trace:\n\(trace)", category: .media)
        resetDiagnostics()
        isStreaming = true
        isSessionAlive = true
        h264Decoder.isSessionAlive = true
        connectionState = .connected
        await PhoneAudioService.shared.startPlayback()
        
        Task {
            // Wait for WebSocket connection to establish on initial launch
            for _ in 0..<30 {
                if ConnectionStateManager.shared.phase == .connected {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            // Safety buffer (500ms) to ensure socket channels are completely initialized on Android
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            let payload: [String: Any] = [
                "action": "START_STREAM"
            ]
            await self.sendControlMessage(payload)
            LinkOSLogger.shared.info("[PhoneSession] (PASS) START_STREAM payload sent initially.", category: .media)
            
        }
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
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneSession] resumeSession called on session [\(ObjectIdentifier(self))] (ID: \(self.sessionId)). Stack Trace:\n\(trace)", category: .media)
        let payload: [String: Any] = [
            "action": "RESUME_STREAM"
        ]
        await sendControlMessage(payload)
        await PhoneAudioService.shared.startPlayback()
    }
    
    func stopSession(isManual: Bool = true) async {
        await tearDown(isManual: isManual, sendRemoteStop: true)
    }
    
    func tearDown(isManual: Bool = true, sendRemoteStop: Bool = true) async {
        LinkOSLogger.shared.info("[PhoneSession] Structured teardown starting for session: \(sessionId)", category: .media)
        isSessionAlive = false
        h264Decoder.invalidate()
        h264Decoder.onPixelBufferDecoded = nil
        self.onPixelBufferReady = nil
        h264Decoder.onDecoderInitialized = nil
        h264Decoder.onDecoderError = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        
        if sendRemoteStop && mirrorState != .stopped && mirrorState != .disconnected && connectionState != .disconnected {
            _ = transitionTo(.stopping)
            let payload: [String: Any] = ["action": "STOP"]
            await sendControlMessage(payload)
        }
        
        self.currentFrame = nil
        self.isStreaming = false
        self.hasShownSuccessNotification = false
        self.hasReceivedFirstFrame = false
        self.connectionState = .disconnected
        _ = transitionTo(.stopped)
        
        await PhoneAudioService.shared.stopPlayback()
        await PhoneAudioService.shared.stopMicCapture()
        LinkOSLogger.shared.info("[PhoneSession] Structured teardown complete for session: \(sessionId)", category: .media)
    }
    
    private func showMirroringSuccessNotification() {
        guard !hasShownSuccessNotification else { return }
        hasShownSuccessNotification = true
        
        let content = UNMutableNotificationContent()
        content.title = "LinkOS Mirroring"
        content.body = "Phone mirrored successfully"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: "pm_success_\(sessionId)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [sessionId] error in
            if let error = error {
                LinkOSLogger.shared.error("Failed to present mirroring success notification: \(error)", category: .media)
            } else {
                LinkOSLogger.shared.info("[PhoneSession] Displayed 'Phone mirrored successfully' notification once for session \(sessionId)", category: .media)
            }
        }
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
    
    func receiveControl(_ data: Data) {
        guard self.isSessionAlive && PhoneSessionManager.shared.activeSession.sessionId == self.sessionId else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let _ = self else { return }
            guard let _ = String(data: data, encoding: .utf8) else { return }
        }
    }

    func receiveFrame(_ data: Data) {
        frameCount += 1

        // Parse frame number for tracing
        if data.count > 15 && data[0] == 0xCC {
            let frameNum = (UInt32(data[2]) << 24) | (UInt32(data[3]) << 16) | (UInt32(data[4]) << 8) | UInt32(data[5])
            PipelineTracker.shared.updateRx(frameNum)
        }

        // Phase 6: Accumulate inter-frame intervals for 1Hz latency smoothing
        let now = Date()
        let interval = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        rawIntervalAccumulator += interval
        rawIntervalCount += 1

        // Mark network connection — one-time dispatch only
        if !hasReceivedFirstFrame {
            hasReceivedFirstFrame = true
            DispatchQueue.main.async {
                LinkOSLogger.shared.info("[PhoneSession] (PASS) First raw frame packet received on Mac: size=\(data.count) bytes", category: .media)
                self.networkStatus = .success
            }
        }

        // Decoder backpressure: ONLY drop frames after the decoder is fully initialized
        // (i.e., after the first successful decode). During initialization the decoder needs
        // SPS (type 7), PPS (type 8), and IDR (type 5) — we must NEVER drop those.
        // Dropping a single SPS/PPS during initialization starves the decoder indefinitely.
        if hasDecoderSucceededOnce && isDecoderBusy {
            droppedFramesSecond += 1
            return
        }
        isDecoderBusy = true

        // Decode H.264 Annex B frame asynchronously on background queue
        self.h264Decoder.receiveNAL(data, frameNetworkRxTs: Date()) { [weak self] in
            // Clear busy flag exactly when the decode block finishes execution on decodeQueue
            self?.isDecoderBusy = false
        }
    }

    // MARK: - Phase 5: Adaptive Quality Controller

    private var qualityLevel: Int = 0  // 0=High(8Mbps), 1=Balanced(5Mbps), 2=Reduced(3Mbps), 3=Minimal(2Mbps)
    private var stableSecondsAtCurrentLevel: Int = 0
    private let bitrateTargets: [Double] = [8000, 5000, 3000, 2000]  // kbps per quality level

    private func adaptQuality(decodedFPS: Int, droppedFrames: Int) {
        // Disabled adaptive quality controller per user request to ensure stream stability
        return
        guard isStreaming else { return }

        let isStressed = droppedFrames > 5 || decodedFPS < 20
        let isHealthy = droppedFrames == 0 && decodedFPS >= 55

        if isStressed && qualityLevel < 3 {
            // Degrade immediately
            qualityLevel += 1
            stableSecondsAtCurrentLevel = 0
            let newBitrate = bitrateTargets[qualityLevel]
            LinkOSLogger.shared.info("[QualityController] Degrading to level \(qualityLevel) (\(Int(newBitrate)) kbps). Dropped: \(droppedFrames)/s, FPS: \(decodedFPS)", category: .media)
            Task { await sendControlMessage(["action": "SET_QUALITY", "bitrate_kbps": newBitrate, "level": qualityLevel]) }
        } else if isHealthy && qualityLevel > 0 {
            stableSecondsAtCurrentLevel += 1
            if stableSecondsAtCurrentLevel >= 5 {
                // Recover gradually after 5 stable seconds
                qualityLevel -= 1
                stableSecondsAtCurrentLevel = 0
                let newBitrate = bitrateTargets[qualityLevel]
                LinkOSLogger.shared.info("[QualityController] Recovering to level \(qualityLevel) (\(Int(newBitrate)) kbps). Healthy for 5s.", category: .media)
                Task { await sendControlMessage(["action": "SET_QUALITY", "bitrate_kbps": newBitrate, "level": qualityLevel]) }
            }
        } else {
            stableSecondsAtCurrentLevel += 1
        }
    }
    
    nonisolated func popLatestFrame() -> (PixelBufferWrapper, FramePipelineMetrics)? {
        return DispatchQueue.main.sync {
            guard let frame = self.latestPixelBuffer else { return nil }
            self.displayedFrameCountSecond += 1
            let metrics = FramePipelineMetrics(captureTs: Date(), encodeTs: Date(), networkRxTs: Date(), decodeTs: Date())
            return (frame, metrics)
        }
    }
    
    func recordPipelineMetrics(_ metrics: FramePipelineMetrics, renderTs: Date) {
        let presentMs = renderTs.timeIntervalSince(metrics.decodeTs) * 1000.0
        self.latencyDecodePresent = (self.latencyDecodePresent * 0.9) + (presentMs * 0.1)
    }
    
    func updateFocusState(entered: Bool, view: NSView) async {
        LinkOSLogger.shared.info("[PhoneSession] updateFocusState: \(entered)", category: .media)
    }
    // MARK: - Inbound Input Injection Actions

    func sendRotateDevice(direction: String) {
        Task { await sendControlMessage(["action": direction]) }
    }
    
    func startScreenRecording() {
        Task { await sendControlMessage(["action": "START_RECORDING"]) }
    }
    
    func stopScreenRecording() {
        Task { await sendControlMessage(["action": "STOP_RECORDING"]) }
    }


    // Input events are time-critical: serialize payload on the calling thread,
    // then fire with .userInteractive priority to skip the cooperative thread pool queue.
    func sendDown(x: Float, y: Float) {
        sendInputNow(["action": "DOWN", "x": x, "y": y])
    }

    func sendHover(x: Float, y: Float) {
        sendInputNow(["action": "HOVER", "x": x, "y": y])
    }

    func sendMove(x: Float, y: Float, startX: Float? = nil, startY: Float? = nil) {
        var payload: [String: Any] = ["action": "MOVE", "x": x, "y": y]
        if let sx = startX, let sy = startY {
            payload["startX"] = sx
            payload["startY"] = sy
        }
        sendInputNow(payload)
    }

    func sendUp(x: Float, y: Float) {
        sendInputNow(["action": "UP", "x": x, "y": y])
    }

    func sendDoubleClick(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "DOUBLE_CLICK", "x": x, "y": y]) }
    }

    func sendLongPress(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "LONG_PRESS", "x": x, "y": y]) }
    }

    func sendDrag(startX: Float, startY: Float, endX: Float, endY: Float, duration: Int = 300) {
        Task { await sendControlMessage(["action": "DRAG", "startX": startX, "startY": startY, "endX": endX, "endY": endY, "duration": duration]) }
    }

    func sendScroll(x: Float, y: Float, deltaX: Float, deltaY: Float) {
        sendInputNow(["action": "SCROLL", "x": x, "y": y, "deltaX": deltaX, "deltaY": deltaY])
    }
    
    func sendGestureStream(gestureType: String, phase: String, x: Float, y: Float, scale: Float, rotation: Float, pressure: Float) {
        Task { await sendControlMessage([
            "action": "GESTURE_STREAM", 
            "gestureType": gestureType, 
            "phase": phase, 
            "x": x, 
            "y": y, 
            "scale": scale, 
            "rotation": rotation, 
            "pressure": pressure
        ]) }
    }

    
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
    
    // MARK: - Private Transport Helpers

    /// Fire-and-forget for time-critical input events (touch, hover, scroll).
    /// Serializes payload immediately on the calling thread (no allocation on the hot path),
    /// then dispatches with .userInteractive priority to skip the cooperative thread pool queue.
    private func sendInputNow(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let activeDevice = AppState.shared.activeConnectedDevice else { return }
        let envelope = MessageRouter.createEvent(channel: ProtocolConstants.Channel.phone, payload: data)
        Task(priority: .userInteractive) { [weak self] in
            guard let self = self else { return }
            do {
                try await AppState.shared.connectionManager?.send(envelope, to: activeDevice.id)
            } catch {
                // Input events are best-effort — don't log at error level for each dropped tap
                LinkOSLogger.shared.debug("[PhoneSession] Input event send failed: \(error.localizedDescription)", category: .media)
            }
        }
    }

    func sendControlMessage(_ payload: [String: Any]) async {
        LinkOSLogger.shared.info("[PhoneSession] (PASS) sendControlMessage triggered with payload: \(payload)", category: .media)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            LinkOSLogger.shared.error("[PhoneSession] (FAIL) Failed to serialize payload or build envelope", category: .media)
            return
        }
        let envelope = MessageRouter.createEvent(channel: ProtocolConstants.Channel.phone, payload: data)
        
        if let activeDevice = AppState.shared.activeConnectedDevice {
            do {
                LinkOSLogger.shared.info("[PhoneSession] (PASS) Sending envelope to device \(activeDevice.id) via ConnectionManager", category: .media)
                try await AppState.shared.connectionManager?.send(envelope, to: activeDevice.id)
                LinkOSLogger.shared.info("[PhoneSession] (PASS) Envelope sent successfully via ConnectionManager", category: .media)
            } catch {
                LinkOSLogger.shared.error("[PhoneSession] (FAIL) Failed to send envelope via ConnectionManager: \(error.localizedDescription)", category: .media)
            }
        } else {
            LinkOSLogger.shared.error("[PhoneSession] (FAIL) No active connected device found in AppState", category: .media)
        }
    }

    // MARK: - AI Agent Screen Context API

    func getPhoneContext() async -> String {
        guard let pixelBufferWrapper = latestPixelBuffer else {
            return "No active phone screen mirrored."
        }
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBufferWrapper.buffer, options: nil, imageOut: &cgImage)
        guard let cgImg = cgImage else {
            return "Failed to extract image from screen buffer."
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
            let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "Failed to perform text recognition: \(error.localizedDescription)")
            }
        }
    }
}

class H264Decoder: @unchecked Sendable {
    static var activeInstanceCount: Int = 0
    
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let decodeQueue = DispatchQueue(label: "com.linkos.h264decoder", qos: .userInteractive)
    
    private var latestSPS: Data?
    private var latestPPS: Data?
    private var pendingIDRFrame: Data?
    
    init() {
        H264Decoder.activeInstanceCount += 1
        LinkOSLogger.shared.info("[Instance Monitor] H264Decoder initialized. Active instances: \(H264Decoder.activeInstanceCount)", category: .media)
    }
    
    // Watchdog Telemetry Counters
    private var receivedPacketCount: Int = 0
    private var spsCount: Int = 0
    private var ppsCount: Int = 0
    private var idrCount: Int = 0
    private var decoderCreationResult: String = "Not Attempted"
    private var lastVTError: String = "None"
    
    var onPixelBufferDecoded: ((PixelBufferWrapper) -> Void)?
    var onDecoderInitialized: (() -> Void)?
    var onDecoderError: ((String) -> Void)?
    var isSessionAlive: Bool = false
    var sessionId: String = ""
    
    func getWatchdogDump() -> String {
        return """
        === VideoToolbox Decoder Watchdog Dump ===
        Received Packets : \(receivedPacketCount)
        SPS Received     : \(spsCount)
        PPS Received     : \(ppsCount)
        IDR Received     : \(idrCount)
        Decoder Creation : \(decoderCreationResult)
        Last VT Error    : \(lastVTError)
        ==========================================
        """
    }
    
    func receiveNAL(_ rawData: Data, frameNetworkRxTs: Date, completion: @escaping () -> Void) {
        guard self.isSessionAlive else {
            completion()
            return
        }
        let rawCopy = Data(rawData) // Reset startIndex to 0 and copy safely for background queue
        decodeQueue.async { [weak self] in
            defer { completion() }
            guard let self = self, self.isSessionAlive else { return }
            self.receivedPacketCount += 1
            
            // Strip LinkOS custom video framing header (Byte 0 = 0xCC, 15 bytes total) before NAL parsing!
            // Without stripping this, Bytes 2-5 (Frame Number e.g. 00 00 00 01) falsely match an Annex-B start code,
            // causing the timestamp byte at Byte 6 to be misinterpreted as NAL Type 31 (0x1F)!
            let data: Data
            var currentFrameNum: UInt32 = 0
            if rawCopy.count > 15 && rawCopy[0] == 0xCC {
                let gen = rawCopy[1]
                let frameNum = (UInt32(rawCopy[2]) << 24) | (UInt32(rawCopy[3]) << 16) | (UInt32(rawCopy[4]) << 8) | UInt32(rawCopy[5])
                currentFrameNum = frameNum
                PipelineTracker.shared.updateDecodeStart(frameNum)
                data = rawCopy.subdata(in: 15..<rawCopy.count)
                if self.receivedPacketCount <= 5 || self.receivedPacketCount % 100 == 0 {
                    LinkOSLogger.shared.debug("[H264Decoder] Stripped 15-byte LinkOS 0xCC video header (Gen: #\(gen), Frame: #\(frameNum), Payload size: \(data.count) bytes)", category: .media)
                }
            } else {
                data = rawCopy
            }
            
            var naluRanges = [Range<Int>]()
            var index = 0
            let bytes = [UInt8](data)
            let len = bytes.count
            
            while index < len - 4 {
                if bytes[index] == 0 && bytes[index+1] == 0 && bytes[index+2] == 0 && bytes[index+3] == 1 {
                    let start = index + 4
                    var end = len
                    var next = start
                    while next < len - 3 {
                        if bytes[next] == 0 && bytes[next+1] == 0 && bytes[next+2] == 0 && bytes[next+3] == 1 {
                            end = next
                            break
                        }
                        if bytes[next] == 0 && bytes[next+1] == 0 && bytes[next+2] == 1 {
                            end = next
                            break
                        }
                        next += 1
                    }
                    naluRanges.append(start..<end)
                    index = end
                } else if bytes[index] == 0 && bytes[index+1] == 0 && bytes[index+2] == 1 {
                    let start = index + 3
                    var end = len
                    var next = start
                    while next < len - 3 {
                        if bytes[next] == 0 && bytes[next+1] == 0 && bytes[next+2] == 0 && bytes[next+3] == 1 {
                            end = next
                            break
                        }
                        if bytes[next] == 0 && bytes[next+1] == 0 && bytes[next+2] == 1 {
                            end = next
                            break
                        }
                        next += 1
                    }
                    naluRanges.append(start..<end)
                    index = end
                } else {
                    index += 1
                }
            }
            
            var videoFrames = [Data]()
            
            var packetNalTypes = [Int]()
            for range in naluRanges {
                guard range.lowerBound >= 0, range.upperBound <= data.count, range.lowerBound < range.upperBound else {
                    continue
                }
                var nalu = data.subdata(in: range)
                while let first = nalu.first, first == 0x00 { nalu.removeFirst() }
                while let last = nalu.last, last == 0x00 { nalu.removeLast() }
                guard !nalu.isEmpty else { continue }
                let type = Int(nalu[0] & 0x1F)
                packetNalTypes.append(type)
                
                let remainingBytes = data.count - range.upperBound
                if self.receivedPacketCount <= 10 || self.receivedPacketCount % 300 == 0 {
                    LinkOSLogger.shared.debug("[H264Decoder] NAL Audit: Type \(type), byte offset: \(range.lowerBound), payload size: \(nalu.count) bytes, remaining in packet: \(remainingBytes) bytes", category: .media)
                }
                
                if type == 7 {
                    if self.latestSPS != nalu {
                        self.latestSPS = nalu
                        if let sess = self.decompressionSession {
                            LinkOSLogger.shared.info("[H264Decoder] SPS changed, invalidating decompression session to recreate dynamically.", category: .media)
                            VTDecompressionSessionInvalidate(sess)
                            self.decompressionSession = nil
                            self.formatDescription = nil
                        }
                    }
                    self.spsCount += 1
                    let hex = nalu.map { String(format: "%02x", $0) }.joined(separator: " ")
                    LinkOSLogger.shared.info("[H264Decoder] Received SPS NALU (\(nalu.count) bytes, offset: \(range.lowerBound), total: \(self.spsCount)): [ \(hex) ]", category: .media)
                } else if type == 8 {
                    if self.latestPPS != nalu {
                        self.latestPPS = nalu
                        if let sess = self.decompressionSession {
                            LinkOSLogger.shared.info("[H264Decoder] PPS changed, invalidating decompression session to recreate dynamically.", category: .media)
                            VTDecompressionSessionInvalidate(sess)
                            self.decompressionSession = nil
                            self.formatDescription = nil
                        }
                    }
                    self.ppsCount += 1
                    let hex = nalu.map { String(format: "%02x", $0) }.joined(separator: " ")
                    LinkOSLogger.shared.info("[H264Decoder] Received PPS NALU (\(nalu.count) bytes, offset: \(range.lowerBound), total: \(self.ppsCount)): [ \(hex) ]", category: .media)
                } else if type == 5 || type == 1 {
                    if type == 5 {
                        self.idrCount += 1
                        self.pendingIDRFrame = nalu
                        LinkOSLogger.shared.info("[H264Decoder] Received IDR Keyframe (\(nalu.count) bytes, offset: \(range.lowerBound), total IDRs: \(self.idrCount)). Preserving for playback.", category: .media)
                    }
                    videoFrames.append(nalu)
                }
            }
            
            if self.receivedPacketCount <= 10 || self.receivedPacketCount % 300 == 0 {
                LinkOSLogger.shared.info("[H264Decoder] Packet #\(self.receivedPacketCount) (\(rawCopy.count) bytes raw, \(data.count) bytes payload) NAL structure: \(packetNalTypes)", category: .media)
            }
            
            self.createFormatDescriptionIfPossible()
            
            guard let formatDesc = self.formatDescription, let session = self.decompressionSession else {
                if !videoFrames.isEmpty && self.decompressionSession == nil {
                    LinkOSLogger.shared.debug("[H264Decoder] Dropped \(videoFrames.count) frames awaiting format description / decompression session.", category: .media)
                }
                return
            }
            
            // Replay any preserved IDR frame if it was dropped during session initialization
            if let preservedIDR = self.pendingIDRFrame {
                if !videoFrames.contains(where: { !($0.isEmpty) && ($0[0] & 0x1F) == 5 }) {
                    LinkOSLogger.shared.info("[H264Decoder] Replaying preserved IDR Keyframe (\(preservedIDR.count) bytes) immediately upon session availability!", category: .media)
                    videoFrames.insert(preservedIDR, at: 0)
                }
                self.pendingIDRFrame = nil
            }
            
            for frame in videoFrames {
                let naluType = frame[0] & 0x1F
                var naluLength = UInt32(frame.count).bigEndian
                var blockBuffer: CMBlockBuffer?
                
                var status = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: frame.count + 4,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: frame.count + 4,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                
                guard status == noErr, let buffer = blockBuffer else { continue }
                
                status = CMBlockBufferReplaceDataBytes(with: &naluLength, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: 4)
                guard status == noErr else { continue }
                
                status = frame.withUnsafeBytes { raw in
                    guard let ptr = raw.baseAddress else { return OSStatus(-1) }
                    return CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: buffer, offsetIntoDestination: 4, dataLength: frame.count)
                }
                guard status == noErr else { continue }
                
                var sampleBuffer: CMSampleBuffer?
                status = CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: buffer,
                    formatDescription: formatDesc,
                    sampleCount: 1,
                    sampleTimingEntryCount: 0,
                    sampleTimingArray: nil,
                    sampleSizeEntryCount: 0,
                    sampleSizeArray: nil,
                    sampleBufferOut: &sampleBuffer
                )
                
                guard status == noErr, let sb = sampleBuffer else { continue }
                
                let sbWrapper = SampleBufferWrapper(sb, frameNum: currentFrameNum)
                
                var flagsOut = VTDecodeInfoFlags()
                if self.receivedPacketCount <= 10 || self.receivedPacketCount % 300 == 0 {
                    LinkOSLogger.shared.info("[H264Decoder] Submitting NALU (type: \(naluType), len: \(frame.count)) to VTDecompressionSessionDecodeFrame...", category: .media)
                }
                status = VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sbWrapper.buffer,
                    flags: [],
                    frameRefcon: Unmanaged.passRetained(sbWrapper).toOpaque(),
                    infoFlagsOut: &flagsOut
                )

                if status != noErr {
                    self.lastVTError = "VTDecompressionSessionDecodeFrame err \(status)"
                    LinkOSLogger.shared.error("[H264Decoder] VTDecompressionSessionDecodeFrame failed with status: \(status) for NAL type \(naluType)", category: .media)
                    if status == kVTInvalidSessionErr {
                        LinkOSLogger.shared.warning("[H264Decoder] Session invalidated (-12903). Resetting decoder.", category: .media)
                        VTDecompressionSessionInvalidate(session)
                        self.decompressionSession = nil
                    }
                }
            }
        }
    }
    
    private func createFormatDescriptionIfPossible() {
        if self.decompressionSession != nil && self.formatDescription != nil {
            return // Already initialized
        }
        guard let spsData = self.latestSPS else {
            LinkOSLogger.shared.debug("[H264Decoder] createFormatDescriptionIfPossible: Exiting early because latestSPS is NULL (SPS Type 7 has not been received in any packet yet).", category: .media)
            return
        }
        guard let ppsData = self.latestPPS else {
            LinkOSLogger.shared.debug("[H264Decoder] createFormatDescriptionIfPossible: Exiting early because latestPPS is NULL (PPS Type 8 has not been received yet, though SPS Type 7 is present).", category: .media)
            return
        }
        LinkOSLogger.shared.info("[H264Decoder] Both SPS (\(spsData.count) bytes) and PPS (\(ppsData.count) bytes) are available! Initiating createFormatDescription...", category: .media)
        self.createFormatDescription(sps: spsData, pps: ppsData)
    }
    
    private func createFormatDescription(sps: Data, pps: Data) {
        let spsHex = sps.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ppsHex = pps.map { String(format: "%02x", $0) }.joined(separator: " ")
        LinkOSLogger.shared.info("[H264Decoder] Creating VideoFormatDescription with SPS (\(sps.count) bytes): [ \(spsHex) ] | PPS (\(pps.count) bytes): [ \(ppsHex) ]", category: .media)
        
        var formatDesc: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-1)
                }
                let parameterSetPointers = [spsPtr, ppsPtr]
                let parameterSetSizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &formatDesc
                )
            }
        }
        
        guard status == noErr, let desc = formatDesc else {
            let msg = "CMVideoFormatDescriptionCreateFromH264ParameterSets failed with status \(status) (SPS size: \(sps.count), PPS size: \(pps.count))"
            self.decoderCreationResult = msg
            self.lastVTError = msg
            LinkOSLogger.shared.error("[H264Decoder] \(msg)", category: .media)
            self.onDecoderError?(msg)
            return
        }
        self.formatDescription = desc
        LinkOSLogger.shared.info("[H264Decoder] CMVideoFormatDescriptionCreateFromH264ParameterSets returned noErr (0). Format description created successfully!", category: .media)
        
        let decoderSpecification: CFDictionary? = nil
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
                var decodedFrameNum: UInt32 = 0
                if let refCon = sourceFrameRefCon {
                    let wrapper = Unmanaged<SampleBufferWrapper>.fromOpaque(refCon).takeRetainedValue() // release wrapper
                    decodedFrameNum = wrapper.frameNum
                    PipelineTracker.shared.updateDecodeEnd(decodedFrameNum)
                }
                
                guard status == noErr, let pixelBuffer = imageBuffer else {
                    LinkOSLogger.shared.error("[H264Decoder] Decompression callback failed! Status: \(status)", category: .media)
                    return
                }
                
                if let decoder = decompressionRefCon {
                    let decoderObject = Unmanaged<H264Decoder>.fromOpaque(decoder).takeUnretainedValue()
                    decoderObject.onPixelBufferDecoded?(PixelBufferWrapper(pixelBuffer, frameNum: decodedFrameNum))
                }
            },
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        if sessionStatus == noErr, let validSession = session {
            VTSessionSetProperty(validSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            VTSessionSetProperty(validSession, key: kVTDecompressionPropertyKey_ThreadCount, value: 1 as CFNumber)
            VTSessionSetProperty(validSession, key: "OutputReordering" as CFString, value: kCFBooleanFalse)
            self.decompressionSession = validSession
            self.decoderCreationResult = "Success (noErr)"
            LinkOSLogger.shared.info("[H264Decoder] VTDecompressionSession created successfully with RealTime properties.", category: .media)
            self.onDecoderInitialized?()
        } else {
            let msg = "VTDecompressionSessionCreate failed with OSStatus: \(sessionStatus)"
            self.decoderCreationResult = msg
            self.lastVTError = msg
            LinkOSLogger.shared.error("[H264Decoder] \(msg)", category: .media)
            self.onDecoderError?(msg)
        }
    }
    
    func invalidate() {
        self.isSessionAlive = false
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            if let session = self.decompressionSession {
                VTDecompressionSessionInvalidate(session)
                self.decompressionSession = nil
            }
            self.formatDescription = nil
            self.latestSPS = nil
            self.latestPPS = nil
            self.pendingIDRFrame = nil
        }
    }
    
    deinit {
        H264Decoder.activeInstanceCount -= 1
        LinkOSLogger.shared.info("[Instance Monitor] H264Decoder deallocated. Active instances: \(H264Decoder.activeInstanceCount)", category: .media)
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}

// MARK: - Pipeline tracing instrumentation helper

final class PipelineTracker: @unchecked Sendable {
    static let shared = PipelineTracker()
    private let lock = NSLock()
    
    var rxFrameId: UInt32 = 0
    var decodeStartFrameId: UInt32 = 0
    var decodeEndFrameId: UInt32 = 0
    var enqueueFrameId: UInt32 = 0
    var renderFrameId: UInt32 = 0
    
    func updateRx(_ frameId: UInt32) {
        lock.lock(); rxFrameId = frameId; lock.unlock()
    }
    func updateDecodeStart(_ frameId: UInt32) {
        lock.lock(); decodeStartFrameId = frameId; lock.unlock()
    }
    func updateDecodeEnd(_ frameId: UInt32) {
        lock.lock(); decodeEndFrameId = frameId; lock.unlock()
    }
    func updateEnqueue(_ frameId: UInt32) {
        lock.lock(); enqueueFrameId = frameId; lock.unlock()
    }
    func updateRender(_ frameId: UInt32) {
        lock.lock(); renderFrameId = frameId; lock.unlock()
    }
    
    func getTraceString() -> String {
        lock.lock()
        defer { lock.unlock() }
        let gap = rxFrameId >= renderFrameId ? (rxFrameId - renderFrameId) : 0
        return "RX: #\(rxFrameId) | DecodeStart: #\(decodeStartFrameId) | Decoded: #\(decodeEndFrameId) | Enqueued: #\(enqueueFrameId) | Rendered: #\(renderFrameId) | Gap: \(gap) frames"
    }
}
