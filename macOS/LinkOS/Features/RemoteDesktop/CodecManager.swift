import Foundation
import VideoToolbox

enum VideoCodecType: String, Codable {
    case hevc = "H.265"
    case avc = "H.264"
    case vp9 = "VP9"
}

/// Negotiates hardware video codec selection (H.265 > H.264 > VP9) based on Apple Silicon hardware acceleration.
final class CodecManager {
    
    func selectBestCodec(peerSupported: [VideoCodecType]) -> VideoCodecType {
        // Preferred hardware acceleration order: H.265 (HEVC) -> H.264 (AVC) -> VP9
        if peerSupported.contains(.hevc) && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            return .hevc
        }
        if peerSupported.contains(.avc) && VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) {
            return .avc
        }
        return .vp9
    }
}

/// Dynamically adjusts streaming bitrate and framerate based on network conditions (RTT, packet loss).
actor AdaptiveBitrateController {
    private(set) var currentBitrateKbps: Int = 4000  // Default 4 Mbps
    private(set) var currentTargetFps: Int = 60
    
    private let minBitrateKbps = 800
    private let maxBitrateKbps = 15000
    
    func updateNetworkQuality(rttMs: Int, packetLossPercent: Double) {
        if rttMs > 100 || packetLossPercent > 5.0 {
            // Degraded network: throttle bitrate down
            currentBitrateKbps = max(minBitrateKbps, Int(Double(currentBitrateKbps) * 0.8))
            currentTargetFps = 30
        } else if rttMs < 30 && packetLossPercent < 1.0 {
            // Excellent network: ramp up
            currentBitrateKbps = min(maxBitrateKbps, Int(Double(currentBitrateKbps) * 1.15))
            currentTargetFps = 60
        }
    }
}
