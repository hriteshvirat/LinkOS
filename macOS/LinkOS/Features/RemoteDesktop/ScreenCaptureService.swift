import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreImage

struct MonitorDisplayInfo: Identifiable, Codable {
    let id: UInt32
    let width: Int
    let height: Int
    let isPrimary: Bool
}

/// Quality presets for Remote Desktop streaming.
enum StreamingQualityPreset: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case high = "High (60 FPS)"
    case low = "Low (15 FPS)"
    
    var id: String { rawValue }
    
    var fps: Int {
        switch self {
        case .auto: return 30
        case .high: return 60
        case .low:  return 15
        }
    }
    
    var resolution: (width: Int, height: Int) {
        switch self {
        case .auto: return (1920, 1080)
        case .high: return (2560, 1440)
        case .low:  return (1280, 720)
        }
    }
    
    var compressionQuality: CGFloat {
        switch self {
        case .auto: return 0.5
        case .high: return 0.7
        case .low:  return 0.3
        }
    }
}

@MainActor
final class ScreenCaptureService: NSObject, ObservableObject {
    @Published var availableDisplays: [MonitorDisplayInfo] = []
    @Published var isStreaming: Bool = false
    @Published var currentPreset: StreamingQualityPreset = .auto
    @Published var selectedDisplayId: UInt32 = CGMainDisplayID()
    
    // Adaptive Quality Metrics
    @Published var currentFPS: Int = 30
    @Published var currentBitrate: String = "—"
    @Published var framesSent: UInt64 = 0
    @Published var framesDropped: UInt64 = 0
    
    private var stream: SCStream?
    private var streamOutput: StreamOutputHandler?
    
    // Auto-restart stream on permission approval
    private var pendingCaptureArgs: (displayID: UInt32, fps: Int, width: Int, height: Int, onFrame: (CMSampleBuffer) -> Void)? = nil
    
    // Adaptive quality state
    private var frameByteAccumulator: UInt64 = 0
    private var frameCountAccumulator: Int = 0
    private var lastBitrateCalcTime: Date = Date()
    
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screenRecordingPermissionGranted), name: NSNotification.Name("LinkOSScreenRecordingGranted"), object: nil)
        Task {
            await refreshDisplays()
        }
    }
    
    @objc private func screenRecordingPermissionGranted() {
        Task {
            await refreshDisplays()
            if let args = self.pendingCaptureArgs {
                LinkOSLogger.shared.info("[RemoteDesktop] Permission granted: Auto-starting pending screen capture stream.", category: .media)
                await startCapture(displayID: args.displayID, fps: args.fps, width: args.width, height: args.height, onFrame: args.onFrame)
            }
        }
    }
    
    func refreshDisplays() async {
        guard PermissionManager.shared.hasPermission(.screenRecording) else {
            return
        }
        do {
            let content = try await SCShareableContent.current
            self.availableDisplays = content.displays.map { display in
                MonitorDisplayInfo(
                    id: display.displayID,
                    width: display.width,
                    height: display.height,
                    isPrimary: display.displayID == CGMainDisplayID()
                )
            }
            LinkOSLogger.shared.info("[RemoteDesktop] Found \(availableDisplays.count) display(s)", category: .media)
        } catch {
            LinkOSLogger.shared.error("Failed to fetch SCShareableContent", category: .media, error: error)
        }
    }
    
    /// Switch to a different display.
    func switchDisplay(to displayId: UInt32) async {
        let wasStreaming = isStreaming
        if wasStreaming {
            await stopCapture()
        }
        selectedDisplayId = displayId
        LinkOSLogger.shared.info("[RemoteDesktop] Switched to display \(displayId)", category: .media)
    }
    
    /// Apply a quality preset.
    func applyPreset(_ preset: StreamingQualityPreset) {
        currentPreset = preset
        currentFPS = preset.fps
        LinkOSLogger.shared.info("[RemoteDesktop] Quality preset: \(preset.rawValue)", category: .media)
    }
    
    /// Adapt quality based on QoS state from ConnectionStateManager.
    func adaptToQoS(targetFPS: Int, targetBitrate: Int) {
        currentFPS = targetFPS
        // Map bitrate to compression quality
        if targetBitrate < 4_000_000 {
            currentPreset = .low
        } else if targetBitrate >= 8_000_000 {
            currentPreset = .high
        } else {
            currentPreset = .auto
        }
        LinkOSLogger.shared.info("[RemoteDesktop] QoS adaptation: FPS=\(targetFPS), preset=\(currentPreset.rawValue)", category: .performance)
    }
    
    func startCapture(displayID: UInt32 = CGMainDisplayID(), fps: Int = 60, width: Int = 1920, height: Int = 1080, onFrame: @escaping (CMSampleBuffer) -> Void) async {
        self.pendingCaptureArgs = (displayID, fps, width, height, onFrame)
        
        guard PermissionManager.shared.hasPermission(.screenRecording) else {
            LinkOSLogger.shared.error("[RemoteDesktop] ERROR: Screen Recording permission denied by macOS System Settings.", category: .media)
            return
        }
        
        do {
            let content = try await SCShareableContent.current
            guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                LinkOSLogger.shared.error("[RemoteDesktop] ERROR: Target display \(displayID) not found", category: .media)
                return
            }
            
            let effectiveFPS = currentFPS > 0 ? currentFPS : fps
            let effectiveWidth = currentPreset.resolution.width
            let effectiveHeight = currentPreset.resolution.height
            
            let filter = SCContentFilter(display: targetDisplay, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = effectiveWidth
            config.height = effectiveHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(effectiveFPS))
            config.queueDepth = 5
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            
            let output = StreamOutputHandler(onFrame: { [weak self] sampleBuffer in
                self?.trackFrame(sampleBuffer)
                onFrame(sampleBuffer)
            })
            self.streamOutput = output
            
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            
            self.stream = stream
            self.isStreaming = true
            self.framesSent = 0
            self.framesDropped = 0
            LinkOSLogger.shared.info("[RemoteDesktop] Capture started (\(effectiveWidth)x\(effectiveHeight) @ \(effectiveFPS) FPS, preset: \(currentPreset.rawValue))", category: .media)
            
        } catch {
            LinkOSLogger.shared.error("[RemoteDesktop] ERROR: ScreenCaptureKit failed to start: \(error.localizedDescription)", category: .media, error: error)
        }
    }
    
    func stopCapture() async {
        self.pendingCaptureArgs = nil
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            self.stream = nil
            self.streamOutput = nil
            self.isStreaming = false
            LinkOSLogger.shared.info("[RemoteDesktop] Capture stopped", category: .media)
        } catch {
            LinkOSLogger.shared.error("[RemoteDesktop] ERROR: Error stopping ScreenCaptureKit: \(error.localizedDescription)", category: .media, error: error)
        }
    }
    
    // MARK: - Frame Tracking
    
    private func trackFrame(_ sampleBuffer: CMSampleBuffer) {
        framesSent += 1
        
        // Calculate bitrate every second
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CVPixelBufferGetDataSize(imageBuffer)
            frameByteAccumulator += UInt64(size)
        }
        frameCountAccumulator += 1
        
        let elapsed = Date().timeIntervalSince(lastBitrateCalcTime)
        if elapsed >= 1.0 {
            let bitsPerSecond = Double(frameByteAccumulator * 8) / elapsed
            let mbps = bitsPerSecond / 1_000_000
            DispatchQueue.main.async {
                self.currentBitrate = String(format: "%.1f Mbps", mbps)
            }
            frameByteAccumulator = 0
            frameCountAccumulator = 0
            lastBitrateCalcTime = Date()
        }
    }
}

private class StreamOutputHandler: NSObject, SCStreamOutput {
    let onFrame: (CMSampleBuffer) -> Void
    
    init(onFrame: @escaping (CMSampleBuffer) -> Void) {
        self.onFrame = onFrame
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        onFrame(sampleBuffer)
    }
}

private let sharedCIContext = CIContext(options: [
    .useSoftwareRenderer: false,
    .priorityRequestLow: false
])

extension ScreenCaptureService {
    nonisolated static func sampleBufferToJPEG(_ sampleBuffer: CMSampleBuffer, compressionQuality: CGFloat = 0.5) -> Data? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return sharedCIContext.jpegRepresentation(
            of: ciImage,
            colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: "kCGImageDestinationLossyCompressionQuality"): compressionQuality]
        )
    }
}
