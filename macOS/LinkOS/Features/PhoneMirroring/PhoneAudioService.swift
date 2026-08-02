import Foundation
import AVFoundation

@MainActor
final class PhoneAudioService: NSObject {
    static let shared = PhoneAudioService()
    
    private var audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    
    private var isPlaying = false
    private var isCapturingMic = false
    
    private var lastPlayoutTime: TimeInterval = 0
    private let latencyTarget: TimeInterval = 0.040 // Target 40ms A/V alignment buffer
    
    private override init() {
        super.init()
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        // Configure 44.1kHz 16-bit Stereo PCM format
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: 2,
            interleaved: true
        )
        
        audioEngine.attach(playerNode)
        if let format = audioFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        }
    }
    
    // MARK: - Playback Handling
    
    func startPlayback() {
        guard !isPlaying else { return }
        do {
            try audioEngine.start()
            playerNode.play()
            isPlaying = true
            LinkOSLogger.shared.info("[PhoneAudioService] AVAudioEngine playback started", category: .media)
        } catch {
            LinkOSLogger.shared.error("[PhoneAudioService] Failed to start AVAudioEngine: \(error.localizedDescription)", category: .media)
        }
    }
    
    func stopPlayback() {
        guard isPlaying else { return }
        playerNode.stop()
        audioEngine.stop()
        isPlaying = false
        LinkOSLogger.shared.info("[PhoneAudioService] AVAudioEngine playback stopped", category: .media)
    }
    
    func receiveAudioPacket(_ data: Data) {
        guard isPlaying, let format = audioFormat else { return }
        
        // Header parsing:
        // Byte 0: 0xAA (Audio identifier)
        // Bytes 1-4: UInt32 timestamp
        // Bytes 5+: PCM data bytes
        guard data.count > 5 else { return }
        
        let timestampBytes = data.subdata(in: 1..<5)
        var timestampValue: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &timestampValue) { timestampBytes.copyBytes(to: $0) }
        timestampValue = CFSwapInt32BigToHost(timestampValue)
        
        let incomingTime = Double(timestampValue) / 1000.0
        let localTime = Date().timeIntervalSince1970
        let drift = localTime - incomingTime
        
        // Latency compensation & drift buffer recovery
        if drift > 0.150 { // If drift exceeds 150ms (latency lag), flush queue to recover
            playerNode.stop()
            playerNode.play()
            LinkOSLogger.shared.warning("[PhoneAudioService] Audio drift detected (\(Int(drift * 1000))ms). Flushed buffer queue to recover sync.", category: .media)
        }
        
        let pcmData = data.subdata(in: 5..<data.count)
        let frameCount = pcmData.count / Int(format.streamDescription.pointee.mBytesPerFrame)
        
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Copy audio bytes into AVAudioPCMBuffer buffer channels
        if let channels = pcmBuffer.int16ChannelData {
            pcmData.withUnsafeBytes { rawBuffer in
                if let baseAddress = rawBuffer.baseAddress {
                    channels[0].initialize(from: baseAddress.assumingMemoryBound(to: Int16.self), count: frameCount * 2)
                }
            }
        }
        
        playerNode.scheduleBuffer(pcmBuffer)
    }
    
    // MARK: - Microphone Streaming
    
    func startMicCapture() {
        guard !isCapturingMic else { return }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Extract PCM mono or stereo mic frames
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }
            
            var micBytes = Data()
            // Byte 0: 0xBB (Mic identifier)
            micBytes.append(0xBB)
            
            // Extract channel data
            if let int16Data = buffer.int16ChannelData {
                let bytesCount = frameCount * 2 // 16-bit = 2 bytes per sample
                let pointer = UnsafeBufferPointer(start: int16Data[0], count: frameCount)
                micBytes.append(pointer)
            }
            
            // Stream mic bytes back to Android
            Task {
                if let connection = await WebSocketServer.shared.activeConnectedDeviceConnection {
                    let envelope = MessageRouter.createEvent(channel: "phone", payload: micBytes)
                    try? await connection.send(envelope)
                }
            }
        }
        
        isCapturingMic = true
        LinkOSLogger.shared.info("[PhoneAudioService] Microphone capture active", category: .media)
    }
    
    func stopMicCapture() {
        guard isCapturingMic else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        isCapturingMic = false
        LinkOSLogger.shared.info("[PhoneAudioService] Microphone capture stopped", category: .media)
    }
}
