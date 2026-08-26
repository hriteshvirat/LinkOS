import SwiftUI

struct DevDiagnosticsOverlay: View {
    @ObservedObject var session: PhoneSession
    @Binding var isShowing: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            
            ScrollView {
                diagnosticSectionsView
            }
            .frame(maxHeight: 250)
            
            Divider().background(Color.white.opacity(0.1))
            
            basicStatsView
            
            Divider().background(Color.white.opacity(0.1))
            
            pipelineStatsView
        }
        .padding(12)
        .background(Color.black.opacity(0.85))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .frame(width: 280)
        .shadow(radius: 15)
    }
    
    @ViewBuilder
    private var headerView: some View {
        HStack {
            Text("🛠 Developer Diagnostics")
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.green)
            Spacer()
            Button(action: { isShowing = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    @ViewBuilder
    private var diagnosticSectionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MAC SIDE").font(.system(size: 10, weight: .bold)).foregroundColor(.blue)
            DevDiagnosticRow(title: "WebSocket Connection", status: session.connectionStatus)
            Divider().background(Color.white.opacity(0.1))
            
            Text("ANDROID SIDE").font(.system(size: 10, weight: .bold)).foregroundColor(.green)
            DevDiagnosticRow(title: "MediaProjection", status: session.mediaProjectionStatus)
            DevDiagnosticRow(title: "Frame Capture", status: session.frameCaptureStatus)
            DevDiagnosticRow(title: "Encoder", status: session.encoderStatus)
            DevDiagnosticRow(title: "Network Delivery", status: session.networkStatus)
            Divider().background(Color.white.opacity(0.1))
            
            Text("MAC DECODER").font(.system(size: 10, weight: .bold)).foregroundColor(.purple)
            DevDiagnosticRow(title: "Decoder", status: session.decoderStatus)
            DevDiagnosticRow(title: "Canvas Renderer", status: session.rendererStatus)
        }
    }
    
    @ViewBuilder
    private var basicStatsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            DevStatsRow(title: "FPS", value: String(format: "%.1f", session.fps))
            DevStatsRow(title: "Bitrate", value: String(format: "%.0f kbps", session.currentBitrateKbps))
            DevStatsRow(title: "Latency (Jitter)", value: String(format: "%.1f ms", session.latencyMs))
        }
    }
    
    @ViewBuilder
    private var pipelineStatsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PIPELINE LATENCY").font(.system(size: 10, weight: .bold)).foregroundColor(.orange)
            DevStatsRow(title: "Capture → Encode", value: String(format: "%.1f ms", session.latencyCaptureEncode))
            DevStatsRow(title: "Encode → Network", value: String(format: "%.1f ms", session.latencyEncodeNetwork))
            DevStatsRow(title: "Network → Decode", value: String(format: "%.1f ms", session.latencyNetworkDecode))
            DevStatsRow(title: "Decode → Present", value: String(format: "%.1f ms", session.latencyDecodePresent))
            DevStatsRow(title: "Total End-to-End Latency", value: String(format: "%.1f ms", session.latencyTotal))
        }
    }
}

struct DevStatsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
        }
    }
}
