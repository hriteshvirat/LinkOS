import Cocoa
import SwiftUI
import Combine
import UserNotifications

final class PhoneWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PhoneWindowController()
    
    private var cancellables = Set<AnyCancellable>()
    @Published var isPiP = false
    private var prePipSize: NSSize = NSSize(width: 390, height: 844)

    /// The floating toolbar panel that lives below the phone window
    private var toolbarPanel: PhoneToolbarPanel?
    private var lastStreamRatio: CGFloat = 0.0

    /// Reentrancy guard: prevents windowDidResize → updateAspectRatio → setFrame → windowDidResize loops.
    private var isUpdatingAspectRatio = false

    /// Reentrancy guard: prevents double-invocation of showWindow() / makeKeyAndOrderFront()
    /// on the same NSWindow instance while an ordering operation is already in-flight.
    private var isShowingWindow = false

    /// Master reentrancy guard for ALL programmatic geometry commits.
    /// When true, any incoming windowDidMove / windowDidResize is a no-op to break
    /// the setFrame → delegate callback → setFrame recursive crash loop.
    private var isCommittingGeometry = false

    /// Safe portrait aspect ratio used before the first stream frame arrives.
    /// Ensures windowWillResize can enforce proportional dragging during connection.
    private static let defaultPortraitRatio: CGFloat = 9.0 / 19.5  // ≈ 0.461

    
    static func defaultContentSize(for ratio: CGFloat, screen: NSScreen?) -> NSSize {
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxH = screenFrame.height - 60
        let maxW = screenFrame.width - 60

        // Baseline raised to 585 × 1268 (≈ 1.5× the old 390 × 844 size).
        let defaultW: CGFloat = 585
        let defaultH: CGFloat = 1268
        let deviceRatio = ratio > 0 ? ratio : (defaultW / defaultH)

        var targetH = defaultH
        var targetW = defaultW

        if targetH > maxH {
            targetH = maxH
            targetW = targetH * deviceRatio
        }
        if targetW > maxW {
            targetW = maxW
            targetH = targetW / deviceRatio
        }

        return NSSize(width: targetW, height: targetH)
    }

    private init() {
        let defaultSize = Self.defaultContentSize(for: 0.0, screen: NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: defaultSize.width, height: defaultSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 150, height: 300)
        window.contentAspectRatio = .zero // Will be set dynamically by incoming stream
        
        super.init(window: window)
        window.delegate = self
        
        // Dynamic title update from PhoneSession metadata
        PhoneSessionManager.shared.$activeSession
            .flatMap { session in
                session.$connectionState
                    .combineLatest(session.$batteryLevel, session.$latencyMs, session.$fps)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak window] (state: PhoneConnectionState, battery: Int, latency: Double, fps: Double) in
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
        
        // Configure SwiftUI hosting view as content view, but use FixedHostingView 
        // to prevent SwiftUI layout invalidations from bubbling up to the NSWindow 
        // and crashing _setFrameCommon during live resizes.
        let contentView = FixedHostingView(rootView: PhoneMirroringRootView())
        window.contentView = contentView
        
        // Create the floating toolbar panel after the window content is set up
        toolbarPanel = PhoneToolbarPanel(attachedTo: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    /// Called when the USER explicitly opens the mirror window.
    /// This is the ONLY place allowed to reset userStoppedMirroring.
    static func showMirror() {
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneWindowController] showMirror: explicit user gesture — resetting userStoppedMirroring. Stack Trace:\n\(trace)", category: .media)
        PhoneSessionManager.shared.userStoppedMirroring = false
        NotificationCenter.default.post(name: NSNotification.Name("PhoneWindowActiveStateChanged"), object: nil)
        shared.showWindow()
    }

    /// Called by system events (e.g. incoming call notification) that may want to show the window.
    /// Does NOT reset userStoppedMirroring — if the user manually disconnected, keep that decision.
    static func showMirrorForIncomingCall() {
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        guard !PhoneSessionManager.shared.userStoppedMirroring else {
            LinkOSLogger.shared.info("[PhoneWindowController] showMirrorForIncomingCall suppressed: userStoppedMirroring=true. Stack Trace:\n\(trace)", category: .media)
            return
        }
        LinkOSLogger.shared.info("[PhoneWindowController] showMirrorForIncomingCall: showing window for system event. Stack Trace:\n\(trace)", category: .media)
        NotificationCenter.default.post(name: NSNotification.Name("PhoneWindowActiveStateChanged"), object: nil)
        shared.showWindow()
    }
    
    static func disconnectMirror() {
        Task {
            await PhoneSessionManager.shared.stopSession()
        }
        shared.lastStreamRatio = 0.0
        shared.window?.orderOut(nil)
        shared.toolbarPanel?.forceHide()
        NotificationCenter.default.post(name: NSNotification.Name("PhoneWindowActiveStateChanged"), object: nil)
        LinkOSLogger.shared.info("[PhoneWindowController] Stream Stopped and Window hidden.", category: .media)
    }
    
    static func forceRetry() {
        shared.window?.orderOut(nil)
        NotificationCenter.default.post(name: NSNotification.Name("PhoneWindowActiveStateChanged"), object: nil)
        showMirror()
    }
    
    static func bringToFront() {
        guard let window = shared.window else { return }
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneWindowController] bringToFront called. ordering window front. Stack Trace:\n\(trace)", category: .media)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func wakeToolbar() {
        toolbarPanel?.pingToolbar()
    }

    /// Eagerly wire onPixelBufferReady on a new session BEFORE SwiftUI's updateNSView runs.
    /// Called by PhoneSessionManager.recreateAndStartSession() immediately after creating the new session,
    /// so decoded frames arriving on the background thread never hit a nil callback.
    func wireSessionEagerly(_ session: PhoneSession) {
        guard let canvas = PhoneMetalCanvasView.current else {
            LinkOSLogger.shared.warning("[PhoneWindowController] wireSessionEagerly: no active PhoneMetalCanvasView - skipping eager wire", category: .media)
            return
        }
        LinkOSLogger.shared.info("[PhoneWindowController] wireSessionEagerly: binding onPixelBufferReady on session \(session.sessionId) to canvas \(ObjectIdentifier(canvas))", category: .media)
        session.onPixelBufferReady = { [weak canvas] pb in
            LinkOSLogger.shared.info("[Pipeline] onPixelBufferReady (eager wire): frame #\(pb.frameNum) -> enqueue", category: .media)
            canvas?.enqueue(pixelBuffer: pb)
        }
    }
    
    func showWindow() {
        guard let window = window else { return }

        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneWindowController] showWindow called. Stack Trace:\n\(trace)", category: .media)

        // Reentrancy guard: makeKeyAndOrderFront on the same window while another
        // ordering operation is in-flight causes AppKit to trap in _setFrameCommon.
        guard !isShowingWindow else { return }
        isShowingWindow = true
        defer { isShowingWindow = false }

        // ── 1. Frame restoration ─────────────────────────────────────────────
        // All frame mutations must be complete BEFORE makeKeyAndOrderFront is called.
        // AppKit re-evaluates the window geometry internally during ordering; any
        // concurrent or post-order setFrame triggers _setFrameCommon crashes.

        // ── Frame restoration ─────────────────────────────────────────────
        // Suppress delegate echo-backs for all geometry mutations below.
        isCommittingGeometry = true

        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            let rectKey = "PhoneWindowFrameRect_\(deviceId)"

            // Presence of a valid saved rect for this device is the only
            // signal we need. The didUserResize flag is no longer consulted
            // because it was ambiguous across sessions.
            var restoredRect: NSRect? = nil
            if let rectString = UserDefaults.standard.string(forKey: rectKey), !rectString.isEmpty {
                let rect = NSRectFromString(rectString)
                if rect.isValidWindowFrame && rect.width >= 280 && rect.height >= 500 && isRectOnAnyScreen(rect) {
                    restoredRect = rect
                } else {
                    UserDefaults.standard.removeObject(forKey: rectKey)
                    LinkOSLogger.shared.warning(
                        "[PhoneWindowController] Discarded invalid saved frame '\(rectString)'",
                        category: .media
                    )
                }
            }
            // Also migrate the old fallback key if the rect key is absent.
            let fallbackKey = "PhoneWindowFrame_\(deviceId)"
            if restoredRect == nil, let savedFrameString = UserDefaults.standard.string(forKey: fallbackKey), !savedFrameString.isEmpty {
                let parts = savedFrameString.components(separatedBy: " ")
                if parts.count >= 4,
                   let x = Double(parts[0]), let y = Double(parts[1]),
                   let w = Double(parts[2]), let h = Double(parts[3]) {
                    let rect = NSRect(x: x, y: y, width: w, height: h)
                    if rect.isValidWindowFrame && rect.width >= 280 && rect.height >= 500 && isRectOnAnyScreen(rect) {
                        restoredRect = rect
                    }
                }
                UserDefaults.standard.removeObject(forKey: fallbackKey)
            }

            if let saved = restoredRect {
                // Restore previous session's frame for this device.
                window.contentAspectRatio = .zero
                window.minSize = NSSize(width: 100, height: 100)
                window.setFrame(saved, display: false)
                isPiP = saved.height < 500
                window.minSize = isPiP ? NSSize(width: 150, height: 320) : NSSize(width: 150, height: 300)
                LinkOSLogger.shared.info("[PhoneWindowController] Restored saved frame for device \(deviceId): \(saved)", category: .media)
            } else {
                // First launch for this device — use the new large default.
                let defaultSize = Self.defaultContentSize(for: Self.defaultPortraitRatio, screen: window.screen)
                window.setContentSize(NSSize(width: defaultSize.width, height: defaultSize.height + 28))
                window.center()
                LinkOSLogger.shared.info("[PhoneWindowController] First launch for device \(deviceId), using default size: \(defaultSize)", category: .media)
            }
        } else {
            let defaultSize = Self.defaultContentSize(for: Self.defaultPortraitRatio, screen: window.screen)
            window.setContentSize(NSSize(width: defaultSize.width, height: defaultSize.height + 28))
            window.center()
        }

        isCommittingGeometry = false

        // Configure window level and screen constraints
        window.level = .normal
        window.collectionBehavior = [.fullScreenPrimary, .managed]

        // ── Pre-stream ratio ──────────────────────────────────────────────────
        // Set a default portrait ratio so windowWillResize can enforce proportional
        // dragging while the device is still connecting (before the first frame).
        // updateAspectRatio will overwrite this with the real ratio on first frame.
        lastStreamRatio = Self.defaultPortraitRatio
        
        // ── 4. Post-order housekeeping ───────────────────────────────────────
        MirroringWorkspace.shared.phoneWindowFrame = window.frame

        if toolbarPanel == nil {
            toolbarPanel = PhoneToolbarPanel(attachedTo: window)
        }

        Task {
            // Guard: if the user explicitly stopped mirroring, showWindow must not auto-start a stream.
            // userStoppedMirroring is only cleared by the explicit showMirror() user gesture.
            guard !PhoneSessionManager.shared.userStoppedMirroring else {
                LinkOSLogger.shared.info("[PhoneWindowController] showWindow task suppressed: userStoppedMirroring=true", category: .media)
                return
            }
            let session = PhoneSessionManager.shared.activeSession
            if session.isSessionAlive {
                LinkOSLogger.shared.info("[PhoneWindowController] showWindow: resuming alive session", category: .media)
                await PhoneSessionManager.shared.resumeSession()
            } else if session.connectionState == .connected {
                LinkOSLogger.shared.info("[PhoneWindowController] showWindow: starting session (connected)", category: .media)
                await session.startSession()
            } else {
                LinkOSLogger.shared.info("[PhoneWindowController] showWindow: recreating and starting session", category: .media)
                await PhoneSessionManager.shared.recreateAndStartSession()
            }
        }

        // ── 5. Ordering ──────────────────────────────────────────────────────
        window.alphaValue = 0.0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }

    }
    
    private func isRectOnAnyScreen(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens {
            if screen.frame.intersects(rect) {
                return true
            }
        }
        return false
    }
    
    func closeMirror() {
        window?.close() // Triggers windowShouldClose
    }
    
    func togglePiP() {
        guard let window = window, !isCommittingGeometry else { return }
        isPiP.toggle()

        isCommittingGeometry = true
        defer { isCommittingGeometry = false }

        if isPiP {
            prePipSize = window.frame.size
            window.level = .floating
            window.minSize = NSSize(width: 150, height: 320)
            window.setContentSize(NSSize(width: 160, height: 346))
            toolbarPanel?.forceHide()
            LinkOSLogger.shared.info("[PhoneWindowController] Entered PiP mode", category: .media)
        } else {
            window.level = .normal
            window.minSize = NSSize(width: 150, height: 300)
            window.setContentSize(prePipSize)
            toolbarPanel?.showImmediately()
            LinkOSLogger.shared.info("[PhoneWindowController] Exited PiP mode", category: .media)
        }
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: window.frame)
    }
    
    // MARK: - NSWindowDelegate
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task {
            await PhoneSessionManager.shared.pauseSession()
            await MainActor.run {
                LinkOSLogger.shared.info("[PhoneWindowController] PhoneWindow hidden, session paused (PhoneWindow reused)", category: .media)
            }
        }
        
        // Hide toolbar panel when phone window closes
        toolbarPanel?.forceHide()
        
        // Save window position configuration
        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            let rectKey = "PhoneWindowFrameRect_\(deviceId)"
            UserDefaults.standard.set(NSStringFromRect(sender.frame), forKey: rectKey)
            // Clear old key to prevent any reuse of crashing frameDescriptor
            let fallbackKey = "PhoneWindowFrame_\(deviceId)"
            UserDefaults.standard.removeObject(forKey: fallbackKey)
        }
        
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            sender.animator().alphaValue = 0.0
        }, completionHandler: {
            sender.orderOut(nil)
            sender.alphaValue = 1.0
        })
        return false // Do NOT destroy the window
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Never auto-resume after an explicit user disconnect
        guard !PhoneSessionManager.shared.userStoppedMirroring else {
            LinkOSLogger.shared.info("[PhoneWindowController] windowDidBecomeKey resumeSession suppressed: userStoppedMirroring=true", category: .media)
            return
        }
        let activeSession = PhoneSessionManager.shared.activeSession
        guard activeSession.isStreaming, activeSession.mirrorState == .paused else { return }
        Task {
            await PhoneSessionManager.shared.resumeSession()
        }
    }
    
    func windowDidResignKey(_ notification: Notification) {
        // Toolbar handles its own hide via NSApplication.didResignActiveNotification
    }
    
    func windowDidMove(_ notification: Notification) {
        // If we are the one committing a frame programmatically, ignore the echo-back.
        guard !isCommittingGeometry else { return }
        guard let w = window, !w.inLiveResize else { return }
        w.logFrame(w.frame, label: "windowDidMove (Start)")
        let frame = w.frame
        // Save position immediately (no async — avoids a DispatchQueue hop that lands
        // after the next resize callback starts, causing a stale-frame commit).
        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "PhoneWindowFrameRect_\(deviceId)")
        }
        // Notify layout coordinator synchronously on main; MirroringLayoutCoordinator
        // only updates its internal model — it does NOT call setFrame on any window.
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: frame)
    }

    func windowDidResize(_ notification: Notification) {
        // During live resize: cache the fact that the user is manually resizing and
        // cache the pending stream size. Do NOT touch setFrame or the coordinator here.
        guard let w = window else { return }
        w.logFrame(w.frame, label: "windowDidResize (inLiveResize=\(w.inLiveResize))")
        if w.inLiveResize {
            // Record user intent — but only during actual hand-dragging.
            if !isCommittingGeometry, let deviceId = AppState.shared.activeConnectedDevice?.id {
                UserDefaults.standard.set(true, forKey: "pm_didUserResize_\(deviceId)")
            }
            // Notify coordinator so floating panels track the live resize
            MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: w.frame)
            // Defer other state saving to windowDidEndLiveResize
            return
        }
        // Non-live (programmatic) resize — save frame and notify.
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: w.frame)
        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "PhoneWindowFrameRect_\(deviceId)")
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let isPiP = sender.level == .floating
        let minW: CGFloat = isPiP ? 120 : 160
        
        // Use lastStreamRatio which is rigorously updated and correct.
        let deviceAspectRatio = lastStreamRatio > 0 ? 1.0 / lastStreamRatio : (1920.0 / 1080.0)
        
        let titleBarHeight: CGFloat = 28
        
        let screenH = sender.screen?.visibleFrame.height ?? 1080
        let screenW = sender.screen?.visibleFrame.width ?? 1920
        
        let toolbarThickness: CGFloat = 52
        let toolbarGap: CGFloat = 12
        let availableH = screenH - toolbarThickness - toolbarGap
        
        let maxW = min(screenW, (availableH - titleBarHeight) / deviceAspectRatio)
        let maxH = maxW * deviceAspectRatio + titleBarHeight
        let minH = minW * deviceAspectRatio + titleBarHeight
        
        // Use averaged axis: derive width from proposed width, then height from that width.
        // This avoids axis-fighting jitter during diagonal and purely horizontal/vertical resize.
        var newW = max(minW, min(maxW, frameSize.width))
        var newH = newW * deviceAspectRatio + titleBarHeight
        
        // Clamp height if it exceeds max
        if newH > maxH {
            newH = maxH
            newW = (newH - titleBarHeight) / deviceAspectRatio
        }
        if newH < minH {
            newH = minH
            newW = (newH - titleBarHeight) / deviceAspectRatio
        }
        
        return NSSize(width: newW.rounded(), height: newH.rounded())
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        toolbarPanel?.forceHide()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard !isCommittingGeometry, let frame = window?.frame else { return }
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: frame)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // CRITICAL: Do NOT call setFrame or updateAspectRatio here.
        // windowDidEndLiveResize fires while _resizeWithEvent is still on the call
        // stack. Any setFrame call re-enters _setFrameCommon which is already
        // executing — this is the exact crash: _adjustNeedsDisplayRegionForNewFrame.
        //
        // The aspect ratio is already enforced live by windowWillResize (pure math).
        // After the drag ends the window stays at the correct size. No correction needed.
        guard let w = window else { return }
        w.logFrame(w.frame, label: "windowDidEndLiveResize")
        let frame = w.frame

        // Save final frame.
        if let deviceId = AppState.shared.activeConnectedDevice?.id {
            UserDefaults.standard.set(NSStringFromRect(frame), forKey: "PhoneWindowFrameRect_\(deviceId)")
        }

        // Sync coordinator so toolbar repositions once — no setFrame involved.
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: frame)
    }
    
    // MARK: - Popup Action Helpers
    
    func setAlwaysOnTop(_ enabled: Bool) {
        window?.level = enabled ? .floating : .normal
        UserDefaults.standard.set(enabled, forKey: "pm_always_on_top")
        LinkOSLogger.shared.info("[PhoneWindowController] Always On Top set to: \(enabled)", category: .media)
    }
    
    func updateAspectRatio(_ size: CGSize) {
        guard let window = window else { return }
        // Silently cache during live resize — windowWillResize handles live
        // aspect-ratio enforcement. updateAspectRatio must NEVER call setFrame
        // while inLiveResize; the coordinator is notified in windowDidEndLiveResize.
        guard !window.inLiveResize else {
            // Just update lastStreamRatio so windowWillResize has the right ratio.
            let r = size.width / size.height
            if r.isFinite, r > 0 { lastStreamRatio = r }
            return
        }
        guard !isUpdatingAspectRatio, !isCommittingGeometry else { return }

        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            LinkOSLogger.shared.warning("[PhoneWindowController] Ignored updateAspectRatio with invalid size: \(size)", category: .media)
            return
        }

        let newRatio = size.width / size.height
        guard newRatio.isFinite, newRatio > 0 else {
            LinkOSLogger.shared.warning("[PhoneWindowController] Ignored updateAspectRatio with non-finite newRatio: \(newRatio)", category: .media)
            return
        }

        // Check orientation changes
        let ratioChanged = abs(self.lastStreamRatio - newRatio) >= 0.005
        let isFirstRealFrame = abs(self.lastStreamRatio - Self.defaultPortraitRatio) < 0.005 && ratioChanged == false
        
        let wasLandscape = self.lastStreamRatio > 1.0
        let isLandscape = newRatio > 1.0
        let orientationChanged = (wasLandscape != isLandscape) && self.lastStreamRatio > 0.005

        if !ratioChanged && !isFirstRealFrame && !orientationChanged && window.frame.width > 0 { return }

        let titleBarHeight: CGFloat = 28
        let currentFrame = window.frame
        let deviceAspectRatio = 1.0 / newRatio // height / width
        
        let screen = window.screen ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        
        let newWinW: CGFloat
        let newWinH: CGFloat

        // Determine if this is the very first real frame from this device.
        let deviceId = AppState.shared.activeConnectedDevice?.id ?? ""
        let savedFrameStr = deviceId.isEmpty ? nil : UserDefaults.standard.string(forKey: "PhoneWindowFrameRect_\(deviceId)")
        let savedFrame = savedFrameStr.flatMap { str -> NSRect? in
            let r = NSRectFromString(str)
            return r.isValidWindowFrame && r.width >= 280 && r.height >= 500 ? r : nil
        }

        if (isFirstRealFrame || orientationChanged) && savedFrame == nil {
            // First frame or rotation: use a beautiful, balanced centered window frame
            if isLandscape {
                newWinH = min(screenFrame.height * 0.7, 600)
                newWinW = (newWinH - titleBarHeight) / deviceAspectRatio
            } else {
                newWinH = min(screenFrame.height * 0.8, 850)
                newWinW = (newWinH - titleBarHeight) / deviceAspectRatio
            }
        } else if (isFirstRealFrame || orientationChanged), let saved = savedFrame {
            // Respect the saved user frame
            newWinH = saved.height
            newWinW = (saved.height - titleBarHeight) / deviceAspectRatio
        } else {
            // Normal resize — keep height, adjust width
            newWinH = currentFrame.height
            newWinW = (currentFrame.height - titleBarHeight) / deviceAspectRatio
        }

        self.lastStreamRatio = newRatio

        let minW: CGFloat = isPiP ? 120 : 320
        window.contentMinSize = NSSize(width: minW, height: minW * deviceAspectRatio)
        window.contentMaxSize = NSSize(width: screenFrame.width, height: screenFrame.height - titleBarHeight)

        // Don't call setFrame when window is at minimum size (except on first frame/rotation)
        let isAtMinSize = currentFrame.width <= minW + 5
        if isAtMinSize && !isFirstRealFrame && !orientationChanged {
            LinkOSLogger.shared.info("[PhoneWindowController] Skipped setFrame in updateAspectRatio — window at min size", category: .media)
            return
        }

        var newFrame = currentFrame
        newFrame.size.width = newWinW
        newFrame.size.height = newWinH

        // Keep centered on screen on first frame or rotation
        if isFirstRealFrame || orientationChanged {
            newFrame.origin.x = screenFrame.minX + (screenFrame.width - newWinW) / 2.0
            newFrame.origin.y = screenFrame.minY + (screenFrame.height - newWinH) / 2.0
        } else {
            // Anchor height and width adjustments to center
            let dh = newWinH - currentFrame.height
            newFrame.origin.y -= dh / 2.0
            let dw = newWinW - currentFrame.width
            newFrame.origin.x -= dw / 2.0
        }

        guard newFrame.isValidWindowFrame else {
            LinkOSLogger.shared.error("[PhoneWindowController] Aborted updateAspectRatio with invalid frame: \(newFrame)", category: .media)
            return
        }

        isUpdatingAspectRatio = true
        isCommittingGeometry = true
        defer {
            isUpdatingAspectRatio = false
            isCommittingGeometry = false
        }

        window.setFrame(newFrame, display: true)
        window.resizeIncrements = NSSize(width: 1, height: 1)

        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: newFrame)
        LinkOSLogger.shared.info("[PhoneWindowController] Aspect ratio updated \(Int(size.width))x\(Int(size.height)) -> window \(Int(newWinW))x\(Int(newWinH))", category: .media)
    }
    
    /// Animated version of updateAspectRatio — used after rotation.
    func animateAspectRatioChange(_ size: CGSize) {
        guard let window = window else { return }
        guard !isUpdatingAspectRatio, !isCommittingGeometry else { return }
        guard !window.inLiveResize else {
            let r = size.width / size.height
            if r.isFinite, r > 0 { lastStreamRatio = r }
            return
        }

        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else { return }
        let newRatio = size.width / size.height
        guard newRatio.isFinite, newRatio > 0 else { return }

        self.lastStreamRatio = newRatio

        let screenScale = window.screen?.backingScaleFactor ?? 2.0
        let contentW = size.width  / screenScale
        let contentH = size.height / screenScale

        let titleBarHeight: CGFloat = 28
        let currentFrame = window.frame

        let availableW = currentFrame.width
        let availableH = max(1.0, currentFrame.height - titleBarHeight)
        let fitScale = min(availableW / contentW, availableH / contentH)
        let newWinW = contentW * fitScale
        let newWinH = contentH * fitScale + titleBarHeight

        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let newFrame = NSRect(x: center.x - newWinW / 2, y: center.y - newWinH / 2, width: newWinW, height: newWinH)
        guard newFrame.isValidWindowFrame else { return }

        let minW: CGFloat = isPiP ? 120 : 320
        window.contentMinSize = NSSize(width: minW, height: minW * (size.height / size.width))
        if let screenFrame = window.screen?.visibleFrame {
            window.contentMaxSize = NSSize(width: screenFrame.width, height: screenFrame.height - titleBarHeight)
        }

        isUpdatingAspectRatio = true
        isCommittingGeometry = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isCommittingGeometry = false
            self.isUpdatingAspectRatio = false
            Task { @MainActor in
                MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: window.frame)
            }
        }
        LinkOSLogger.shared.info("[PhoneWindowController] Animated aspect-ratio change to \(Int(size.width))x\(Int(size.height))", category: .media)
    }
    
    /// Fit to Window is now always active — this method is kept as a no-op stub for call-site compatibility.
    func setFitToWindow(_ enabled: Bool) {
        LinkOSLogger.shared.info("[PhoneWindowController] setFitToWindow called (no-op, fit is always active): \(enabled)", category: .media)
    }
    
    func setActualSize() {
        guard let window = window, let frame = PhoneSessionManager.shared.activeSession.currentFrame else { return }
        guard !isCommittingGeometry else { return }
        let scale = window.screen?.backingScaleFactor ?? 2.0
        let targetW = CGFloat(frame.width) / scale
        let targetH = CGFloat(frame.height) / scale
        guard targetW.isFinite, targetH.isFinite, targetW >= 1, targetH >= 1 else {
            LinkOSLogger.shared.error("[PhoneWindowController] Aborted setActualSize with invalid dimensions: \(targetW)x\(targetH)", category: .media)
            return
        }
        isCommittingGeometry = true
        defer { isCommittingGeometry = false }
        window.setContentSize(NSSize(width: targetW, height: targetH + 28))
        window.center()
        UserDefaults.standard.set(false, forKey: "pm_fit_to_window")
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: window.frame)
        LinkOSLogger.shared.info("[PhoneWindowController] Actual Size set to: \(Int(targetW))x\(Int(targetH + 28))", category: .media)
    }
    
    func getLinkOSDownloadsURL(subfolder: String? = nil) -> URL? {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        var linkOSFolder = downloads.appendingPathComponent("LinkOS", isDirectory: true)
        if let sub = subfolder {
            linkOSFolder = linkOSFolder.appendingPathComponent(sub, isDirectory: true)
        }
        if !FileManager.default.fileExists(atPath: linkOSFolder.path) {
            try? FileManager.default.createDirectory(at: linkOSFolder, withIntermediateDirectories: true, attributes: nil)
        }
        return linkOSFolder
    }
    
    func sendMediaSavedNotification(title: String, fileURL: URL) {
        let content = UNMutableNotificationContent()
        content.title = title
        
        let relPath = fileURL.path.components(separatedBy: "Downloads/").last ?? fileURL.lastPathComponent
        content.body = "~/Downloads/\(relPath)"
        
        content.sound = .default
        content.categoryIdentifier = "MEDIA_SAVED"
        content.userInfo = ["filePath": fileURL.path]
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LinkOSLogger.shared.error("Failed to present media notification: \(error)", category: .media)
            }
        }
    }
    
    func rotateWindowAndPreview(left: Bool) {
        let session = PhoneSessionManager.shared.activeSession
        session.sendRotateDevice(direction: left ? "ROTATE_LEFT" : "ROTATE_RIGHT")
    }
    
    func takeScreenshot() {
        guard let window = window else { return }
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(.zero, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) else {
            LinkOSLogger.shared.error("[PhoneWindowController] Failed to capture window screenshot", category: .media)
            return
        }
        
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }
        
        guard let linkOSDir = getLinkOSDownloadsURL(subfolder: "Screenshots") else { return }
        let fileURL = linkOSDir.appendingPathComponent("LinkOS_Screenshot_\(Int(Date().timeIntervalSince1970)).png")
        do {
            try pngData.write(to: fileURL)
            LinkOSLogger.shared.info("[PhoneWindowController] Screenshot saved to \(fileURL.path)", category: .media)
            NSSound(named: "ScreenCapture")?.play()
            sendMediaSavedNotification(title: "Screenshot Saved", fileURL: fileURL)
        } catch {
            LinkOSLogger.shared.error("[PhoneWindowController] Failed to write screenshot: \(error.localizedDescription)", category: .media)
        }
    }
    
    func toggleScreenRecording(_ recording: Bool) {
        LinkOSLogger.shared.info("[PhoneWindowController] Screen recording toggled to: \(recording)", category: .media)
        if recording {
            PhoneSessionManager.shared.activeSession.startScreenRecording()
        } else {
            PhoneSessionManager.shared.activeSession.stopScreenRecording()
        }
        let payload: [String: Any] = [
            "action": "TOGGLE_RECORDING",
            "enabled": recording
        ]
        Task { await PhoneSessionManager.shared.activeSession.sendControlMessage(payload) }
    }
}

extension NSRect {
    var isValidWindowFrame: Bool {
        origin.x.isFinite &&
        origin.y.isFinite &&
        width.isFinite &&
        height.isFinite &&
        width >= 1 &&
        height >= 1
    }
}

/// A specialized NSHostingView that prevents SwiftUI from pushing intrinsic size
/// updates to its parent window. This breaks the AppKit reentrancy loop where
/// rapid @Published state updates (e.g., FPS counters) trigger layout passes
/// that crash _setFrameCommon during live resizing.
private class FixedHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
