import Foundation
import AVFoundation

final class PhoneAudioService: NSObject, @unchecked Sendable {
    static let shared = PhoneAudioService()
    
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timePitch: AVAudioUnitTimePitch?
    private var audioFormat: AVAudioFormat?
    
    private let audioQueue = DispatchQueue(label: "com.linkos.audio", qos: .userInteractive)
    
    private var isPlaying = false
    private var isCapturingMic = false
    
    // Audio Metrics
    private var droppedPackets = 0
    private var duplicatePackets = 0
    private var underruns = 0
    private var overruns = 0
    private var lastTimestamp: UInt32 = 0
    private var bufferDepthFrames: AVAudioFrameCount = 0
    
    // Jitter Buffer & Clock Sync
    private var baseIncomingTime: Double = 0
    private var baseLocalTime: Double = 0
    
    private override init() {
        super.init()
    }
    
    private func setupAudioEngineIfNeeded() {
        guard audioEngine == nil else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        
        // Configure 48kHz 16-bit Stereo PCM format to match Android exactly
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 2,
            interleaved: true
        )
        
        engine.attach(player)
        engine.attach(pitch)
        
        engine.connect(player, to: pitch, format: nil)
        engine.connect(pitch, to: engine.mainMixerNode, format: nil)
        
        audioEngine = engine
        playerNode = player
        timePitch = pitch
    }
    
    // MARK: - Playback Handling
    
    func startPlayback() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isPlaying else { return }
            self.setupAudioEngineIfNeeded()
            
            do {
                try self.audioEngine?.start()
                self.playerNode?.play()
                self.isPlaying = true
                self.resetMetrics()
                LinkOSLogger.shared.info("[Audio Queue] AVAudioEngine playback started (48kHz)", category: .media)
            } catch {
                LinkOSLogger.shared.error("[Audio Queue] Failed to start AVAudioEngine: \(error.localizedDescription)", category: .media)
            }
        }
    }
    
    func stopPlayback() {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isPlaying else { return }
            self.playerNode?.stop()
            self.audioEngine?.stop()
            self.isPlaying = false
            self.baseIncomingTime = 0
            self.baseLocalTime = 0
            LinkOSLogger.shared.info("[Audio Queue] AVAudioEngine playback stopped. Final Metrics: \(self.getMetricsReport())", category: .media)
        }
    }
    
    private func resetMetrics() {
        droppedPackets = 0
        duplicatePackets = 0
        underruns = 0
        overruns = 0
        lastTimestamp = 0
        bufferDepthFrames = 0
    }
    
    func getMetricsReport() -> String {
        return "Dropped: \(droppedPackets), Duplicates: \(duplicatePackets), Underruns: \(underruns), Overruns: \(overruns)"
    }
    
    func receiveAudioPacket(_ rawData: Data) {
        audioQueue.async { [weak self] in
            guard let self = self, self.isPlaying else { return }
            guard UserDefaults.standard.bool(forKey: "pm_audio_sync") else { return }
            let data = Data(rawData)
            guard data.count > 6 else { return }
            
            let timestampBytes = data.subdata(in: 2..<6)
            var timestampValue: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &timestampValue) { timestampBytes.copyBytes(to: $0) }
            timestampValue = CFSwapInt32BigToHost(timestampValue)
            
            if self.lastTimestamp == timestampValue {
                self.duplicatePackets += 1
                return
            }
            if self.lastTimestamp != 0 && timestampValue > self.lastTimestamp + 25 {
                self.droppedPackets += 1
            }
            self.lastTimestamp = timestampValue
            
            let incomingTime = Double(timestampValue) / 1000.0
            let localTime = Date().timeIntervalSince1970
            
            if self.baseLocalTime == 0 || self.baseIncomingTime == 0 {
                self.baseLocalTime = localTime
                self.baseIncomingTime = incomingTime
            }
            
            let relativeIncoming = incomingTime - self.baseIncomingTime
            let relativeLocal = localTime - self.baseLocalTime
            let drift = relativeLocal - relativeIncoming
            
            // Tight Jitter Buffer & Video PTS synchronization
            if drift > 0.140 { 
                // Audio fell >140ms behind video due to jitter/buffering. Flush to snap back into sync!
                self.playerNode?.stop()
                self.playerNode?.play()
                self.baseLocalTime = localTime
                self.baseIncomingTime = incomingTime
                self.overruns += 1
                LinkOSLogger.shared.info("[Audio Sync] Flushed stale audio buffer to resynchronize with PTS (Drift was \(Int(drift*1000))ms)", category: .media)
                return
            } else if drift > 0.040 { 
                self.timePitch?.rate = 1.06
            } else if drift < -0.040 {
                self.timePitch?.rate = 0.95
                self.underruns += 1
            } else {
                self.timePitch?.rate = 1.0
            }
            
            guard data.count > 6 else { return }
            let pcmData = data.subdata(in: 6..<data.count)
            let frameCount = pcmData.count / 4 // 16-bit stereo = 4 bytes per frame
            guard frameCount > 0 else { return }
            
            let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: standardFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            
            pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
            
            if let floatChannelData = pcmBuffer.floatChannelData {
                let leftChannel = floatChannelData[0]
                let rightChannel = floatChannelData[1]
                
                pcmData.withUnsafeBytes { rawBuffer in
                    if let int16Ptr = rawBuffer.bindMemory(to: Int16.self).baseAddress {
                        for i in 0..<frameCount {
                            leftChannel[i] = Float32(int16Ptr[i * 2]) / 32768.0
                            rightChannel[i] = Float32(int16Ptr[i * 2 + 1]) / 32768.0
                        }
                    }
                }
            }
            
            self.playerNode?.scheduleBuffer(pcmBuffer)
        }
    }
    
    // MARK: - Microphone Streaming
    
    func startMicCapture() {
        audioQueue.async { [weak self] in
            guard let self = self, !self.isCapturingMic else { return }
            self.setupAudioEngineIfNeeded()
            guard let engine = self.audioEngine else { return }
            
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }
                
                var micBytes = Data()
                micBytes.append(0xBB)
                
                if let int16Data = buffer.int16ChannelData {
                    let pointer = UnsafeBufferPointer(start: int16Data[0], count: frameCount)
                    micBytes.append(pointer)
                }
                
                Task {
                    if let connection = await WebSocketServer.shared.activeConnectedDeviceConnection {
                        let envelope = MessageRouter.createEvent(channel: "phone", payload: micBytes)
                        try? await connection.send(envelope)
                    }
                }
            }
            self.isCapturingMic = true
            LinkOSLogger.shared.info("[Audio Queue] Microphone capture active", category: .media)
        }
    }
    
    func stopMicCapture() {
        audioQueue.async { [weak self] in
            guard let self = self, self.isCapturingMic else { return }
            self.audioEngine?.inputNode.removeTap(onBus: 0)
            self.isCapturingMic = false
            LinkOSLogger.shared.info("[Audio Queue] Microphone capture stopped", category: .media)
        }
    }
}
