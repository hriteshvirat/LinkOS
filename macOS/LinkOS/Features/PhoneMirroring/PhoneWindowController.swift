import Cocoa
import SwiftUI
import Combine

final class PhoneWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PhoneWindowController()
    
    private var cancellables = Set<AnyCancellable>()
    @Published var isPiP = false
    private var prePipSize: NSSize = NSSize(width: 390, height: 844)
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 390, height: 844),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.backgroundColor = .black
        
        super.init(window: window)
        window.delegate = self
        
        // Dynamic title update from PhoneSession metadata
        PhoneSession.shared.$connectionState
            .combineLatest(PhoneSession.shared.$batteryLevel, PhoneSession.shared.$latencyMs, PhoneSession.shared.$fps)
            .receive(on: DispatchQueue.main)
            .sink { [weak window] state, battery, latency, fps in
                guard let window = window else { return }
                let deviceName = AppState.shared.activeConnectedDevice?.name ?? "Android Phone"
                switch state {
                case .connected:
                    window.title = "\(deviceName) • Connected • \(battery)% • \(Int(latency))ms • \(Int(fps)) FPS"
                case .reconnecting:
                    window.title = "\(deviceName) • Reconnecting... • \(battery)%"
                case .connecting:
                    window.title = "\(deviceName) • Connecting..."
                case .disconnected:
                    window.title = "Phone"
                }
            }
            .store(in: &cancellables)
            
        // Configure Swift UI hosting view as content view
        let contentView = NSHostingView(rootView: PhoneMirroringView())
        window.contentView = contentView
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func showMirror() {
        guard let window = window else { return }
        
        // Restore coordinates based on active device ID
        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            let key = "PhoneWindowFrame_\(deviceId)"
            if let savedFrameString = UserDefaults.standard.string(forKey: key) {
                window.setFrame(from: savedFrameString)
            } else {
                window.setContentSize(NSSize(width: 390, height: 844))
                window.center()
            }
        } else {
            window.setContentSize(NSSize(width: 390, height: 844))
            window.center()
        }
        
        window.makeKeyAndOrderFront(nil)
        
        Task {
            if !PhoneSession.shared.isStreaming {
                await PhoneSession.shared.startSession()
            } else {
                await PhoneSession.shared.resumeSession()
            }
        }
    }
    
    func closeMirror() {
        window?.close()
    }
    
    func togglePiP() {
        guard let window = window else { return }
        isPiP.toggle()
        
        if isPiP {
            prePipSize = window.frame.size
            window.level = .floating
            window.setContentSize(NSSize(width: 160, height: 346))
            LinkOSLogger.shared.info("[PhoneWindowController] Entered PiP mode", category: .media)
        } else {
            window.level = .normal
            window.setContentSize(prePipSize)
            LinkOSLogger.shared.info("[PhoneWindowController] Exited PiP mode", category: .media)
        }
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Pauses streaming but keeps session alive for sub-second reopen
        Task {
            await PhoneSession.shared.pauseSession()
        }
        
        // Save window position configuration
        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            let key = "PhoneWindowFrame_\(deviceId)"
            UserDefaults.standard.set(sender.frameDescriptor, forKey: key)
        }
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Keyboard focus binds automatically
        guard PhoneSession.shared.isStreaming else { return }
        Task {
            await PhoneSession.shared.resumeSession()
        }
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // Focus return to macOS handled automatically when resigning key status
    }
}
