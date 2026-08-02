import Foundation
import AVFoundation

/// Manages macOS system audio capture and streaming to Android client.
/// Automatically falls back to default input microphone if a virtual loopback device is not present.
@MainActor
final class AudioSyncService: NSObject {
    public static let shared = AudioSyncService()
    
    private var audioEngine: AVAudioEngine?
    private var isStreaming = false
    private var isMuted = false
    private var volume: Float = 1.0
    private var isAudioOnlyMode = false
    private var playerNode = AVAudioPlayerNode()
    
    private let logger = LinkOSLogger.shared
    
    private override init() {
        super.init()
    }
    
    private func ensureEngineStarted() {
        if audioEngine == nil {
            let engine = AVAudioEngine()
            let mainMixer = engine.mainMixerNode
            
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false) else { return }
            
            engine.attach(playerNode)
            engine.connect(playerNode, to: mainMixer, format: format)
            
            do {
                try engine.start()
                self.audioEngine = engine
                logger.info("AVAudioEngine started successfully", category: .media)
            } catch {
                logger.error("Failed to start AVAudioEngine: \(error.localizedDescription)", category: .media)
            }
        }
    }
    
    /// Starts real-time system audio capture and dispatches compressed audio frames.
    func startStreaming() {
        ensureEngineStarted()
        guard !isStreaming else { return }
        guard let engine = audioEngine else { return }
        
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // Output format: 44.1kHz, 1 channel (mono) for efficient bandwidth utilization
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false) else {
            logger.error("Failed to create target audio conversion format", category: .media)
            return
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            logger.error("Failed to initialize AVAudioConverter", category: .media)
            return
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self, self.isStreaming, !self.isMuted else { return }
            
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024)!
            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            
            if status == .haveData, error == nil {
                self.dispatchAudioBuffer(outputBuffer)
            }
        }
        
        self.isStreaming = true
        logger.info("System audio loopback stream initialized successfully", category: .media)
    }
    
    /// Stops the audio capture pipeline cleanly.
    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine?.stop()
        audioEngine = nil
        logger.info("System audio loopback stream terminated", category: .media)
    }
    
    func setMute(_ muted: Bool) {
        self.isMuted = muted
        logger.info("Audio stream mute status set to: \(muted)", category: .media)
    }
    
    func setVolume(_ vol: Float) {
        self.volume = max(0.0, min(1.0, vol))
        logger.info("Audio stream volume level adjusted to: \(vol)", category: .media)
    }
    
    func setAudioOnlyMode(_ enabled: Bool) {
        self.isAudioOnlyMode = enabled
        logger.info("Audio-only streaming mode adjusted to: \(enabled)", category: .media)
    }
    
    private func dispatchAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let bufferSize = frameLength * MemoryLayout<Float>.size
        
        let audioData = Data(bytes: floatData, count: bufferSize)
        
        // Wrap frame with timestamp for sync with Remote Desktop video frames
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let payload: [String: Any] = [
            "timestamp_ms": timestampMs,
            "volume": volume,
            "audio_only": isAudioOnlyMode,
            "data": audioData.base64EncodedString()
        ]
        
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload) {
            Task {
                await ConnectionStateManager.shared.routeMessage(channel: .audio, payload: payloadData, from: DeviceIdentity.deviceId)
            }
        }
    }
    
    func playReceivedAudioChunk(data: Data) {
        ensureEngineStarted()
        guard let engine = audioEngine, engine.isRunning else { return }
        
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false) else { return }
        
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Float>.size)
        guard frameCount > 0 else { return }
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount
        
        data.withUnsafeBytes { bufferPointer in
            if let floatChannelData = pcmBuffer.floatChannelData?[0] {
                memcpy(floatChannelData, bufferPointer.baseAddress, data.count)
            }
        }
        
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(pcmBuffer, at: nil, options: [], completionHandler: nil)
    }
}
