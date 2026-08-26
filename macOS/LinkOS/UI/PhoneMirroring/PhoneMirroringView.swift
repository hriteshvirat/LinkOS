import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PhoneMirroringView: View {
    @ObservedObject var session: PhoneSession
    
    @State private var timeoutTimer: Timer? = nil
    @State private var showDevDiagnostics = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Call Integration Overlay UI
            if session.callState == "RINGING" {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📞 Incoming Call")
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.white)
                            Text(session.incomingCallNumber)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            Button(action: {
                                Task { await session.rejectCall() }
                            }) {
                                Image(systemName: "phone.down.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: {
                                Task { await session.acceptCall() }
                            }) {
                                Image(systemName: "phone.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.green)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .padding()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: session.callState)
                .zIndex(100)
            } else if session.callState == "OFFHOOK" {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("📞 Active Call")
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.green)
                            Text(session.incomingCallNumber)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 12) {
                            Button(action: {
                                Task { await session.transferCallToHandset() }
                            }) {
                                Image(systemName: "phone.arrow.up.right")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.blue)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Transfer Call to Phone")
                            
                            Button(action: {
                                Task { await session.endCall() }
                            }) {
                                Image(systemName: "phone.down.fill")
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Hang Up")
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .padding()
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: session.callState)
                .zIndex(100)
            }
            
            if session.mirrorState == .presenting || session.mirrorState == .streaming || session.rendererStatus == .success || session.currentFrame != nil {
                ZStack {
                    // Video fills the content area below the titlebar (respects safe area).
                    // The window's windowWillResize math already subtracts titleBarHeight,
                    // so the content area has the exact device aspect ratio — no bars.
                    PhoneMetalCanvasViewRepresentable(session: session)
                        .ignoresSafeArea(edges: [.horizontal, .bottom])
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            LinkOSLogger.shared.info("[Pipeline Transition 3/4] PhoneMetalCanvasViewRepresentable appeared in SwiftUI body (Session ID: \(session.sessionId), ObjectIdentifier: \(ObjectIdentifier(session)))", category: .media)
                        }
                    
                    TouchRippleView(location: session.tapLocation, trigger: session.tapTrigger)
                    
                    if session.connectionState == .reconnecting {
                        VStack {
                            HStack(spacing: 10) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                                    .frame(width: 16, height: 16)
                                
                                Text("Reconnecting...")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(.white)
                                
                                Button(action: {
                                    PhoneWindowController.disconnectMirror()
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(Color.gray)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                                    .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 5)
                            )
                            .padding(.top, 16)
                            
                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: session.connectionState)
                        .zIndex(50)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1.0)
                )
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
            } else if session.diagnosticsTimeoutReached {
                VStack(spacing: 24) {
                    HStack {
                        Spacer()
                        Button(action: {
                            session.diagnosticsTimeoutReached = false
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.6))
                                .padding()
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.horizontal)
                    .padding(.top, 10)
                    
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    
                    Text("Connection Timeout")
                        .font(.system(.title2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text("The screen mirroring stream took too long to start. Here is the diagnostic status of the connection pipeline:")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    
                    // Pipeline Status — 3-Section Diagnostic Model
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            macSideDiagnosticsView
                            
                            if session.mediaProjectionStatus == .pending && session.connectionStatus == .success {
                                waitingIndicatorView
                            } else {
                                Divider().background(Color.white.opacity(0.15))
                            }
                            
                            androidSideDiagnosticsView
                            
                            Divider().background(Color.white.opacity(0.15))
                            
                            macDecoderDiagnosticsView
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .frame(maxHeight: 320)
                    .padding(.horizontal, 24)
                    
                    if !session.lastErrorMessage.isEmpty {
                        Text("Error: \(session.lastErrorMessage)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.red)
                            .padding(.horizontal, 24)
                            .multilineTextAlignment(.center)
                    }
                    
                    HStack(spacing: 16) {
                        Button(action: {
                            session.resetDiagnostics()
                            startDiagnosticsTimer()
                            Task {
                                await session.startSession()
                            }
                        }) {
                            Text("Retry")
                                .fontWeight(.semibold)
                                .foregroundColor(.black)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                        
                        Button(action: {
                            let url = URL(string: "https://github.com/hriteshvirat/LinkOS/blob/main/docs/Troubleshooting.md")!
                            NSWorkspace.shared.open(url)
                        }) {
                            Text("Troubleshoot")
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.15))
                                .cornerRadius(8)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
            } else {
                PhoneWaitingUI(session: session)
            }
            
            // Developer Diagnostics Panel (from ⋯ → Developer → Show Diagnostics)
            if showDevDiagnostics {
                VStack {
                    DevDiagnosticsOverlay(session: session, isShowing: $showDevDiagnostics)
                        .padding(.top, session.callState == "RINGING" ? 120 : 40)
                        .padding(.leading, 16)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showDevDiagnostics)
                .zIndex(90)
            }
        }
        .onAppear {
            startDiagnosticsTimer()
        }
        .onDisappear {
            stopDiagnosticsTimer()
        }
    }
    
    // MARK: - Actions
    
    private func startDiagnosticsTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
            Task { @MainActor in
                if PhoneSessionManager.shared.activeSession.rendererStatus != .success {
                    PhoneSessionManager.shared.activeSession.diagnosticsTimeoutReached = true
                }
            }
        }
    }
    
    private func stopDiagnosticsTimer() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }
    
    @ViewBuilder
    private var macSideDiagnosticsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac Side")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
            DiagnosticRow(title: "WebSocket Connection", status: session.connectionStatus)
        }
    }
    
    @ViewBuilder
    private var waitingIndicatorView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
            Text("Waiting for Android...")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.orange)
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var androidSideDiagnosticsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Android Side")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
            DiagnosticRow(title: "MediaProjection Granted", status: session.mediaProjectionStatus)
            DiagnosticRow(title: "Screen Capture (VirtualDisplay)", status: session.frameCaptureStatus)
            DiagnosticRow(title: "Encoder Running", status: session.encoderStatus)
            DiagnosticRow(title: "Network Delivery (SPS/PPS/Frames)", status: session.networkStatus)
        }
    }
    
    @ViewBuilder
    private var macDecoderDiagnosticsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mac Decoder")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
            DiagnosticRow(title: "VideoToolbox Decoder", status: session.decoderStatus)
            DiagnosticRow(title: "Canvas Renderer / Present", status: session.rendererStatus)
            
            if !session.watchdogDump.isEmpty {
                Text(session.watchdogDump)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(8)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(6)
                    .padding(.top, 4)
            }
        }
    }
}

struct DiagnosticRow: View {
    let title: String
    let status: DiagnosticStageStatus
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            switch status {
            case .pending:
                HStack(spacing: 4) {
                    Image(systemName: "circle")
                        .foregroundColor(.gray)
                    Text("Pending")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.gray)
                }
            case .success:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Success")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.green)
                }
            case .failure(let error):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Error: \(error)")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.red)
                }
            case .inProgress(let statusText):
                HStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                        .scaleEffect(0.6)
                    Text(statusText)
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

struct DevDiagnosticRow: View {
    let title: String
    let status: DiagnosticStageStatus
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
            Spacer()
            switch status {
            case .pending:
                HStack(spacing: 4) {
                    Image(systemName: "circle")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                    Text("Pending")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.gray)
                }
            case .success:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text("Success")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.green)
                }
            case .failure(let error):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text("Error")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.red)
                }
                .help(error)
            case .inProgress(let statusText):
                HStack(spacing: 4) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                        .scaleEffect(0.5)
                    Text(statusText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

// Low-overhead CALayer ViewRepresentable wrapper bypassing SwiftUI rendering cycle
struct PhoneDisplayCanvasViewRepresentable: NSViewRepresentable {
    let frame: CGImage
    
    func makeNSView(context: Context) -> PhoneDisplayCanvasView {
        let view = PhoneDisplayCanvasView()
        view.updateFrame(frame)
        return view
    }
    
    func updateNSView(_ nsView: PhoneDisplayCanvasView, context: Context) {
        // No longer pumping frames via SwiftUI updateNSView to avoid coalescing latency
    }
}

final class PhoneDisplayCanvasView: NSView {
    private let contentLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.isOpaque = true
        
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.isOpaque = true
        layer?.addSublayer(contentLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, !bounds.width.isNaN, !bounds.height.isNaN else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
        updateTrackingAreas()
    }
    
    func updateFrame(_ frame: CGImage) {
        // Obsolete: Now handled by CVDisplayLink in renderOnVsync
    }
    
    // MARK: - VSync Rendering
    
    private var displayLink: CVDisplayLink?
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupDisplayLink()
        } else {
            teardownDisplayLink()
        }
    }
    
    private func setupDisplayLink() {
        teardownDisplayLink()
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }
        
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkSetOutputCallback(displayLink, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            let view = Unmanaged<PhoneDisplayCanvasView>.fromOpaque(displayLinkContext!).takeUnretainedValue()
            view.renderOnVsync()
            return kCVReturnSuccess
        }, context)
        
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
        LinkOSLogger.shared.info("[Render Thread] CVDisplayLink started for zero-latency vsync", category: .media)
    }
    
    private func teardownDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
            LinkOSLogger.shared.info("[Render Thread] CVDisplayLink stopped", category: .media)
        }
    }
    
    private func renderOnVsync() {
        // Poll atomic latest frame on the background display link thread
        guard let latestTuple = PhoneSessionManager.shared.activeSession.popLatestFrame() else { return }
        
        let latestFrame = latestTuple.0
        let metrics = latestTuple.1
        
        // Present immediately on the display link thread, completely bypassing main thread
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.contentLayer.contents = latestFrame
        CATransaction.commit()
        
        let renderTs = Date()
        DispatchQueue.main.async {
            PhoneSessionManager.shared.activeSession.recordPipelineMetrics(metrics, renderTs: renderTs)
        }
    }
    
    // MARK: - Mouse Hover & Tracking Areas (Hides mouse inside phone display canvas)
    
    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .mouseMoved]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func mouseEntered(with event: NSEvent) {
        NSCursor.hide()
    }
    
    override func mouseExited(with event: NSEvent) {
        NSCursor.unhide()
    }
    
    // MARK: - Direct Input Events Forwarding
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseDown(at: loc, viewSize: bounds.size)
    }
    
    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseDragged(to: loc, viewSize: bounds.size)
    }
    
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleMouseUp(at: loc, viewSize: bounds.size)
    }
    
    override func scrollWheel(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        PhoneInputService.shared.handleScroll(at: loc, event: event, viewSize: bounds.size)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let base64 = png.base64EncodedString()
                    PhoneSessionManager.shared.activeSession.sendClipboardImage(base64)
                    return
                }
            }
        }
        PhoneInputService.shared.handleKeyDown(with: event)
    }
}

// Background Blur visual effect view utility
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Dark Gray Color Extension for UI fallback consistency
extension Color {
    static let darkGray = Color(NSColor.darkGray)
}

struct TouchRippleView: View {
    let location: CGPoint?
    let trigger: Int
    @State private var scale: CGFloat = 0.2
    @State private var opacity: Double = 0.0
    
    var body: some View {
        GeometryReader { proxy in
            if let loc = location, opacity > 0.01 {
                Circle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 42, height: 42)
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .position(x: loc.x * proxy.size.width, y: loc.y * proxy.size.height)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger, perform: { _ in
            scale = 0.2
            opacity = 0.8
            withAnimation(.easeOut(duration: 0.35)) {
                scale = 2.0
                opacity = 0.0
            }
        })
    }
}
