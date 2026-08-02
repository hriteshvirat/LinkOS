import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PhoneMirroringView: View {
    @StateObject private var session = PhoneSession.shared
    @State private var showControlsOverlay = false
    @State private var showNavigationOverlay = false
    
    // Configurable navigation overlay modes: "Always Show", "Auto-hide", "Disabled"
    @AppStorage("phone_navigation_overlay_mode") private var navMode = "Auto-hide"
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if session.isStreaming, let frame = session.currentFrame {
                PhoneDisplayCanvasViewRepresentable(frame: frame)
                    .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                    .padding(12) // Outer Bezel spacing
                    .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
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
            } else {
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text("Waiting for Android device...")
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(.gray)
                    Text("Make sure LinkOS companion app is active on your phone and permissions are enabled.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.darkGray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            
            // Hover Overlay Control Panel (Screenshot, PiP, Record, Disconnect)
            VStack {
                Spacer()
                if showControlsOverlay {
                    HStack(spacing: 16) {
                        Button(action: { triggerScreenshot() }) {
                            Image(systemName: "camera.fill")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Take Screenshot")
                        
                        Button(action: { togglePiP() }) {
                            Image(systemName: "pip.fill")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Picture in Picture")
                        
                        Button(action: { toggleRecording() }) {
                            Image(systemName: "record.circle")
                                .foregroundColor(.red)
                                .padding(10)
                                .background(Color.white.opacity(0.15))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Record Mirrored Session")
                        
                        Button(action: { disconnectSession() }) {
                            Image(systemName: "power")
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Disconnect")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).cornerRadius(28))
                    .shadow(radius: 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
                }
            }
            
            // Optional Navigation Overlay (Back, Home, Recents)
            VStack {
                Spacer()
                if shouldShowNavigationOverlay {
                    HStack(spacing: 40) {
                        Button(action: { session.sendKey("KEY_BACK") }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Back")
                        
                        Button(action: { session.sendKey("KEY_HOME") }) {
                            Image(systemName: "circle")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Home")
                        
                        Button(action: { session.sendKey("KEY_RECENTS") }) {
                            Image(systemName: "square")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Recents")
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(20)
                    .padding(.bottom, showControlsOverlay ? 80 : 20)
                    .transition(.opacity)
                }
            }
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showControlsOverlay = hovering
                if navMode == "Auto-hide" {
                    showNavigationOverlay = hovering
                }
            }
        }
    }
    
    private var shouldShowNavigationOverlay: Bool {
        if navMode == "Always Show" {
            return true
        } else if navMode == "Auto-hide" {
            return showNavigationOverlay
        }
        return false
    }
    
    // MARK: - Actions Triggers
    
    private func triggerScreenshot() {
        // Screenshots trigger handled locally or requested from Android
    }
    
    private func togglePiP() {
        // Shrink window toggle
    }
    
    private func toggleRecording() {
        // Recording frame triggers
    }
    
    private func disconnectSession() {
        Task {
            await session.stopSession()
            PhoneWindowController.shared.closeMirror()
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
        nsView.updateFrame(frame)
    }
}

final class PhoneDisplayCanvasView: NSView {
    private let contentLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        
        contentLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(contentLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
        updateTrackingAreas()
    }
    
    func updateFrame(_ frame: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = frame
        CATransaction.commit()
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
        PhoneInputService.shared.handleScroll(with: event, viewSize: bounds.size)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let base64 = png.base64EncodedString()
                    PhoneSession.shared.sendClipboardImage(base64)
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
