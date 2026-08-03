import Foundation
import Combine
import AppKit
import CoreGraphics
import Vision
import VideoToolbox
import CoreMedia

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
    @Published var connectionStatus: DiagnosticStageStatus = .pending
    @Published var mediaProjectionStatus: DiagnosticStageStatus = .pending
    @Published var frameCaptureStatus: DiagnosticStageStatus = .pending
    @Published var encoderStatus: DiagnosticStageStatus = .pending
    @Published var networkStatus: DiagnosticStageStatus = .pending
    @Published var decoderStatus: DiagnosticStageStatus = .pending
    @Published var rendererStatus: DiagnosticStageStatus = .pending
    @Published var diagnosticsTimeoutReached: Bool = false
    @Published var lastErrorMessage: String = ""
    
    private var lastFrameTime = Date()
    private var frameCount = 0
    private var fpsTimer: Timer?
    private let h264Decoder = H264Decoder()
    
    private init() {
        // Calculate FPS periodically
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.fps = Double(self.frameCount)
                self.frameCount = 0
            }
        }
        
        h264Decoder.onFrameDecoded = { [weak self] cgImage in
            guard let self = self else { return }
            Task { @MainActor in
                if self.decoderStatus != .success {
                    LinkOSLogger.shared.info("[PhoneSession] (PASS) Frame #1 successfully decoded on Mac", category: .media)
                    self.decoderStatus = .success
                }
                self.currentFrame = cgImage
                if self.rendererStatus != .success {
                    LinkOSLogger.shared.info("[PhoneSession] (PASS) Renderer updated with currentFrame", category: .media)
                    self.rendererStatus = .success
                }
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
        case "frame_capture":
            frameCaptureStatus = status
        case "encoder_initialized":
            encoderStatus = ok ? .inProgress("Encoder Initialized") : .failure(error)
        case "encoder_started":
            encoderStatus = ok ? .inProgress("Encoder Started") : .failure(error)
        case "first_sps_pps":
            encoderStatus = ok ? .inProgress("First SPS/PPS Received") : .failure(error)
        case "first_frame":
            encoderStatus = ok ? .inProgress("First Frame Received") : .failure(error)
        case "encoder":
            encoderStatus = status
        case "network":
            networkStatus = status
        case "decoder":
            decoderStatus = status
        case "renderer":
            rendererStatus = status
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
        LinkOSLogger.shared.info("[PhoneSession] (PASS) startSession called", category: .media)
        resetDiagnostics()
        let payload: [String: Any] = [
            "action": "START_STREAM"
        ]
        await sendControlMessage(payload)
        LinkOSLogger.shared.info("[PhoneSession] (PASS) START_STREAM payload serialized & sent via ConnectionStateManager", category: .media)
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
        if networkStatus != .success {
            DispatchQueue.main.async {
                LinkOSLogger.shared.info("[PhoneSession] (PASS) First raw frame packet received on Mac: size=\(data.count) bytes", category: .media)
                self.networkStatus = .success
            }
        }
        
        // Decode H.264 Annex B frame asynchronously on background queue
        DispatchQueue.global(qos: .userInteractive).async {
            self.h264Decoder.decode(data)
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

class H264Decoder: @unchecked Sendable {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let decodeQueue = DispatchQueue(label: "com.linkos.h264decoder")
    
    var onFrameDecoded: ((CGImage) -> Void)?
    
    func decode(_ data: Data) {
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
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
            
            var sps: Data?
            var pps: Data?
            var videoFrames = [Data]()
            
            for range in naluRanges {
                let nalu = data.subdata(in: range)
                guard !nalu.isEmpty else { continue }
                let type = nalu[0] & 0x1F
                
                if type == 7 {
                    sps = nalu
                } else if type == 8 {
                    pps = nalu
                } else if type == 5 || type == 1 {
                    videoFrames.append(nalu)
                }
            }
            
            if let spsData = sps, let ppsData = pps {
                self.createFormatDescription(sps: spsData, pps: ppsData)
            }
            
            guard let formatDesc = self.formatDescription, let session = self.decompressionSession else { return }
            
            for frame in videoFrames {
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
                
                let frameBytes = [UInt8](frame)
                status = CMBlockBufferReplaceDataBytes(with: frameBytes, blockBuffer: buffer, offsetIntoDestination: 4, dataLength: frame.count)
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
                
                var flagsOut = VTDecodeInfoFlags()
                status = VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sb,
                    flags: [._EnableAsynchronousDecompression],
                    frameRefcon: nil,
                    infoFlagsOut: &flagsOut
                )
            }
        }
    }
    
    private func createFormatDescription(sps: Data, pps: Data) {
        let spsPointer = sps.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }
        let ppsPointer = pps.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }
        
        guard let spsPtr = spsPointer, let ppsPtr = ppsPointer else { return }
        
        let parameterSetPointers = [spsPtr, ppsPtr]
        let parameterSetSizes = [sps.count, pps.count]
        
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc
        )
        
        guard status == noErr, let desc = formatDesc else { return }
        self.formatDescription = desc
        
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
        }
        
        let decoderSpecification: CFDictionary? = nil
        let destinationImageBufferAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferOpenGLCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (decompressionRefCon, sourceFrameRefCon, status, infoFlags, imageBuffer, presentationTimeStamp, presentationDuration) in
                guard status == noErr, let pixelBuffer = imageBuffer else { return }
                
                var cgImage: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
                
                if let cgImg = cgImage, let decoder = decompressionRefCon {
                    let decoderObject = Unmanaged<H264Decoder>.fromOpaque(decoder).takeUnretainedValue()
                    decoderObject.onFrameDecoded?(cgImg)
                }
            },
            decompressionOutputRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        
        var session: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: destinationImageBufferAttributes,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        if sessionStatus == noErr {
            self.decompressionSession = session
        }
    }
    
    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
