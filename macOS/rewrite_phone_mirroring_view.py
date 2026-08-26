import sys

with open('/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/UI/PhoneMirroring/PhoneMirroringView.swift', 'r') as f:
    lines = f.readlines()

# Find the end of PhoneMirroringView struct
end_idx = -1
for i in range(500, 520):
    if lines[i].startswith('}'):
        end_idx = i
        break

new_content = """import AppKit
import UniformTypeIdentifiers
import AVFoundation
import SwiftUI

struct PhoneMirroringView: View {
    @StateObject private var session = PhoneSession.shared
    @State private var isHoveringToolbarArea = false
    @State private var showDevDiagnostics = false
    @State private var timeoutTimer: Timer? = nil
    
    // Configurable navigation overlay modes: "Always Show", "Auto-hide", "Disabled"
    @AppStorage("phone_navigation_overlay_mode") private var navMode = "Auto-hide"
    @AppStorage("use_sample_buffer_layer") private var useSampleBufferLayer = false
    
    var body: some View {
        HStack(spacing: 0) {
            // BlueStacks-style Toolbar Area
            ZStack(alignment: .leading) {
                // Invisible trigger area
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 30)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isHoveringToolbarArea = hovering
                        }
                    }
                
                // Toolbar or Glass Strip
                if isHoveringToolbarArea {
                    PhoneMirroringToolbar(session: session, showDevDiagnostics: $showDevDiagnostics)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .padding(.leading, 8)
                } else {
                    // Thin 8px glass strip
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 6, height: 100)
                        .padding(.leading, 4)
                        .shadow(color: Color.black.opacity(0.3), radius: 4, x: 2, y: 0)
                }
            }
            .frame(width: isHoveringToolbarArea ? 70 : 30)
            .zIndex(10)
            
            // Main Phone Area
            VStack(spacing: 0) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    PhoneDisplayCanvasViewRepresentable(frame: session.currentFrame)
                        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .padding(12) // Outer Bezel spacing
                        .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
                        .opacity(session.isStreaming ? 1.0 : 0.0)
                        .animation(.default, value: session.isStreaming)
                        .onChange(of: session.currentFrame != nil) { hasFrame in
                            if hasFrame && session.rendererStatus == .pending {
                                session.updateDiagnostic(stage: "renderer", ok: true, error: "", sessionId: session.sessionId)
                                session.isStreaming = true
                            }
                        }
                    
                    if !session.isStreaming {
                        PhoneWaitingUI(session: session)
                    }
                    
                    // Call Integration Overlay UI
                    CallIntegrationOverlay(session: session)
                    
                    if session.connectionState == .reconnecting {
                        VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                            .padding(12)
                            .overlay(
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.2)
                                    Text("Connection Lost")
                                        .font(.system(.headline, design: .rounded))
                                        .foregroundColor(.white)
                                    Text("Reconnecting to phone...")
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundColor(.gray)
                                }
                            )
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, error in
                            if let url = url {
                                Task {
                                    if let filesPlugin = await AppState.shared.pluginManager?.getPlugin(FileSystemPlugin.self) {
                                        try? await filesPlugin.uploadLocalFileToAndroid(filePath: url.path, targetDirectory: "/sdcard/Download")
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
                
                // Native Android Bottom Navigation Bar
                if session.isStreaming {
                    AndroidBottomNavigationBar(session: session)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showDevDiagnostics {
                DevDiagnosticsOverlay(session: session, isShowing: $showDevDiagnostics)
                    .padding(24)
            }
        }
        .onAppear {
            startDiagnosticsTimer()
        }
        .onDisappear {
            stopDiagnosticsTimer()
        }
        .onReceive(session.$rendererStatus) { status in
            if status == .success || status == .inProgress("First Frame Decoded") || status == .inProgress("First Decode Submitted") {
                stopDiagnosticsTimer()
            }
        }
    }
    
    private func startDiagnosticsTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            Task { @MainActor in
                if PhoneSession.shared.rendererStatus != .success && PhoneSession.shared.isStreaming == false {
                    PhoneSession.shared.diagnosticsTimeoutReached = true
                }
            }
        }
    }
    
    private func stopDiagnosticsTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
}
"""

with open('/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/UI/PhoneMirroring/PhoneMirroringView.swift', 'w') as f:
    f.write(new_content)
    f.writelines(lines[end_idx+1:])

