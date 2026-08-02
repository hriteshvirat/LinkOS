import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import CoreVideo

/// Translates remote touch and trackpad events into native macOS CGEvents.
/// Enhanced with:
/// - CVDisplayLink-synchronized cursor warping
/// - Subpixel floating-point accumulation
/// - Simple Kalman-filter motion prediction
/// - Packet coalescing (aggregate sub-ms packets)
/// - Refresh-rate detection and adaptive pacing
/// - Latency instrumentation
final class InputInjectionService {
    static let shared = InputInjectionService()
    
    private var subpixelAccumulatorX: Double = 0.0
    private var subpixelAccumulatorY: Double = 0.0
    private var smoothedDX: Double = 0.0
    private var smoothedDY: Double = 0.0
    private var isDraggingState: Bool = false
    private(set) var lastMoveLatencyMs: Double = 0
    private(set) var averageLatencyMs: Double = 0
    private var latencySamples: [Double] = []
    private let maxLatencySamples = 100
    private(set) var detectedRefreshRate: Double = 60.0
    private var lastEventTime: CFTimeInterval = 0
    private var localCursorPos: CGPoint? = nil
    private var cachedScreenHeight: CGFloat? = nil
    private var smoothedVelocity: Double = 0.0
    private var accumulatedZoomScroll: Double = 0.0
    private var lastZoomTime: CFTimeInterval = 0.0
    
    // Accumulators and Locks for event coalescing
    private let moveLock = NSLock()
    private var pendingDX: Double = 0.0
    private var pendingDY: Double = 0.0
    private var displayLink: CVDisplayLink?
    private var lastPacketTime: CFTimeInterval = 0.0
    private var lastTickTime: CFTimeInterval = 0.0
    private var tickCount = 0
    
    private var isScrollScheduled = false
    private var pendingScrollX: Double = 0.0
    private var pendingScrollY: Double = 0.0
    private let scrollLock = NSLock()
    
    private let inputQueue = DispatchQueue(label: "com.linkos.inputQueue", qos: .userInteractive)
    
    private var systemTrackingSpeed: Double {
        if let dict = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain),
           let scaling = dict["com.apple.trackpad.scaling"] as? Double {
            return max(0.5, scaling * 1.0)
        }
        return 1.5
    }
    
    private init() {
        detectRefreshRate()
        startDisplayLink()
    }
    
    deinit {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }
    
    private func detectRefreshRate() {
        if let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) {
            let rate = mode.refreshRate
            detectedRefreshRate = rate > 0 ? rate : 60.0
        }
    }
    
    private func startDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }
        
        let callback: CVDisplayLinkOutputCallback = { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            let service = Unmanaged<InputInjectionService>.fromOpaque(displayLinkContext!).takeUnretainedValue()
            service.tickDisplayLink()
            return kCVReturnSuccess
        }
        
        CVDisplayLinkSetOutputCallback(displayLink, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(displayLink)
        self.displayLink = displayLink
    }
    
    // MARK: - Cursor Movement
    
    func moveCursor(deltaX: Double, deltaY: Double, sensitivity: Double = 1.0) {
        let cursorSens = UserDefaults.standard.double(forKey: "linkos_trackpad_cursor_sensitivity")
        let sensVal = cursorSens > 0 ? cursorSens : 1.0
        
        let gamingMode = UserDefaults.standard.bool(forKey: "linkos_trackpad_gaming_mode")
        let precisionMode = UserDefaults.standard.bool(forKey: "linkos_trackpad_precision_mode")
        
        var baseMultiplier = 0.85
        if gamingMode {
            baseMultiplier = 0.90
        } else if precisionMode {
            baseMultiplier = 0.35
        }
        
        let actualSens = (sensVal + 3.0) * 1.5
        let speed = self.systemTrackingSpeed * actualSens * sensitivity * baseMultiplier
        let dx = deltaX * speed
        let dy = deltaY * speed
        
        moveLock.lock()
        lastPacketTime = CACurrentMediaTime()
        if dx == 0.0 && dy == 0.0 {
            pendingDX = 0.0
            pendingDY = 0.0
            moveLock.unlock()
            return
        }
        
        pendingDX += dx
        pendingDY += dy
        moveLock.unlock()
    }
    
    private func tickDisplayLink() {
        moveLock.lock()
        
        let totalDist = sqrt(pendingDX * pendingDX + pendingDY * pendingDY)
        
        if totalDist < 0.001 {
            pendingDX = 0.0
            pendingDY = 0.0
            lastTickTime = CACurrentMediaTime()
            moveLock.unlock()
            return
        }
        
        // Periodically refresh the main display's refresh rate to handle screen switches/configs
        tickCount += 1
        if tickCount % 500 == 0 {
            detectRefreshRate()
        }
        
        let now = CACurrentMediaTime()
        var dt = now - lastTickTime
        
        // Dynamically compute the maximum frame period based on detected display rate
        // Cap at 4.0 frames or 50ms to allow all typical OS scheduling variations (avoiding stutter)
        // while still handling system sleeps/blocks safely.
        let refreshPeriod = 1.0 / detectedRefreshRate
        let maxDt = min(refreshPeriod * 4.0, 0.050)
        
        if dt <= 0.0005 { dt = refreshPeriod }
        if dt > maxDt   { dt = refreshPeriod }
        lastTickTime = now
        
        let elapsed = now - lastPacketTime
        if totalDist < 0.05 && elapsed > 0.040 {
            // Flush tiny residual when input has stopped
            let restX = pendingDX
            let restY = pendingDY
            pendingDX = 0.0
            pendingDY = 0.0
            
            // Re-synchronize localCursorPos with system position on stop to prevent drift
            let height = self.cachedScreenHeight ?? NSScreen.main?.frame.height ?? 1080
            let nsLoc = NSEvent.mouseLocation
            self.localCursorPos = CGPoint(x: nsLoc.x, y: height - nsLoc.y)
            
            moveLock.unlock()
            if restX != 0.0 || restY != 0.0 {
                injectMoveStep(dx: restX, dy: restY)
            }
            return
        }
        
        // Time-step-invariant exponential decay spring.
        // step = pending * (1 - exp(-λ * dt))
        // λ is smoothly interpolated (not step-thresholded) to avoid velocity discontinuities
        // at threshold crossings which would appear as micro-jumps/skips.
        //
        //   dist → 0:  λ = 40   (extremely soft — precise small movements, eliminates finger tremor/vibration)
        //   dist = 0.5:λ = 55
        //   dist = 3.0:λ = 95   (standard velocity, optimized for medium-speed tracking smoothness)
        //   dist >= 8.0:λ = 150 (instant responsive large sweeps)
        let lambda: Double
        if totalDist >= 8.0 {
            lambda = 150.0
        } else if totalDist >= 3.0 {
            // Smooth interpolation between 95 and 150
            let t = (totalDist - 3.0) / 5.0
            lambda = 95.0 + t * 55.0
        } else if totalDist >= 0.5 {
            // Smooth interpolation between 55 and 95
            let t = (totalDist - 0.5) / 2.5
            lambda = 55.0 + t * 40.0
        } else if totalDist >= 0.1 {
            // Smooth interpolation between 40 and 55 to damp tremors at very small/micro slides
            let t = (totalDist - 0.1) / 0.4
            lambda = 40.0 + t * 15.0
        } else {
            lambda = 40.0
        }
        
        let decay = 1.0 - exp(-lambda * dt)
        
        let stepX = pendingDX * decay
        let stepY = pendingDY * decay
        
        pendingDX -= stepX
        pendingDY -= stepY
        moveLock.unlock()
        
        injectMoveStep(dx: stepX, dy: stepY)
    }
    
    private func injectMoveStep(dx: Double, dy: Double) {
        let startTime = CACurrentMediaTime()
        let target: CGPoint
        
        if let currentPos = self.localCursorPos {
            target = CGPoint(x: currentPos.x + dx, y: currentPos.y + dy)
            self.localCursorPos = target
        } else {
            let height = NSScreen.main?.frame.height ?? 1080
            self.cachedScreenHeight = height
            
            let nsLoc = NSEvent.mouseLocation
            let current = CGPoint(x: nsLoc.x, y: height - nsLoc.y)
            target = CGPoint(x: current.x + dx, y: current.y + dy)
            self.localCursorPos = target
        }
        
        subpixelAccumulatorX += dx
        subpixelAccumulatorY += dy
        let intDX = Int64(round(subpixelAccumulatorX))
        let intDY = Int64(round(subpixelAccumulatorY))
        subpixelAccumulatorX -= Double(intDX)
        subpixelAccumulatorY -= Double(intDY)
        
        let mouseType: CGEventType = self.isDraggingState ? .leftMouseDragged : .mouseMoved
        
        if let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: target, mouseButton: .left) {
            event.setIntegerValueField(.mouseEventDeltaX, value: intDX)
            event.setIntegerValueField(.mouseEventDeltaY, value: intDY)
            event.post(tap: .cghidEventTap)
        }
        let latency = (CACurrentMediaTime() - startTime) * 1000
        self.lastMoveLatencyMs = latency
        self.latencySamples.append(latency)
        if self.latencySamples.count > self.maxLatencySamples {
            self.latencySamples.removeFirst()
        }
        self.averageLatencyMs = self.latencySamples.reduce(0, +) / Double(self.latencySamples.count)
    }
    
    // MARK: - Dragging Support
    
    func dragStart() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isDraggingState = true
            let nsLoc = NSEvent.mouseLocation
            let mainScreenHeight = NSScreen.main?.frame.height ?? 1080
            let pos = CGPoint(x: nsLoc.x, y: mainScreenHeight - nsLoc.y)
            if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pos, mouseButton: .left) {
                down.post(tap: .cghidEventTap)
            }
        }
    }
    
    func dragEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isDraggingState = false
            let nsLoc = NSEvent.mouseLocation
            let mainScreenHeight = NSScreen.main?.frame.height ?? 1080
            let pos = CGPoint(x: nsLoc.x, y: mainScreenHeight - nsLoc.y)
            if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pos, mouseButton: .left) {
                up.post(tap: .cghidEventTap)
            }
        }
    }
    
    // MARK: - Clicks
    
    func click(button: CGMouseButton = .left, count: Int = 1) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let nsLoc = NSEvent.mouseLocation
            let mainScreenHeight = NSScreen.main?.frame.height ?? 1080
            let pos = CGPoint(x: nsLoc.x, y: mainScreenHeight - nsLoc.y)
            
            let downType: CGEventType = (button == .left) ? .leftMouseDown : (button == .right ? .rightMouseDown : .otherMouseDown)
            let upType: CGEventType = (button == .left) ? .leftMouseUp : (button == .right ? .rightMouseUp : .otherMouseUp)
            
            for _ in 0..<count {
                if let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: pos, mouseButton: button) {
                    down.post(tap: .cghidEventTap)
                }
                usleep(10000) // 10ms click hold duration
                if let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: pos, mouseButton: button) {
                    up.post(tap: .cghidEventTap)
                }
            }
        }
    }
    
    // MARK: - Scroll
    
    func scroll(deltaX: Double, deltaY: Double) {
        scrollLock.lock()
        pendingScrollX += deltaX
        pendingScrollY += deltaY
        
        if isScrollScheduled {
            scrollLock.unlock()
            return
        }
        isScrollScheduled = true
        scrollLock.unlock()
        
        inputQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.scrollLock.lock()
            let dx = self.pendingScrollX
            let dy = self.pendingScrollY
            self.pendingScrollX = 0.0
            self.pendingScrollY = 0.0
            self.isScrollScheduled = false
            self.scrollLock.unlock()
            
            self.performScroll(deltaX: dx, deltaY: dy)
        }
    }
    
    private func performScroll(deltaX: Double, deltaY: Double) {
        var dx = deltaX
        var dy = deltaY
        
        let natural = UserDefaults.standard.object(forKey: "linkos_trackpad_scroll_direction_natural") as? Bool ?? true
        if !natural {
            dx = -dx
            dy = -dy
        }
        
        let scrollSens = UserDefaults.standard.double(forKey: "linkos_trackpad_scrolling_sensitivity")
        let sensitivity = (scrollSens > 0 ? scrollSens : 1.0) * 0.6
        
        dx *= sensitivity
        dy *= sensitivity
        
        let intX = Int32(round(dx))
        let intY = Int32(round(dy))
        
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: intY, wheel2: intX, wheel3: 0) else { return }
        
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        
        event.post(tap: .cgSessionEventTap)
    }
    
    // MARK: - System Gestures (Mission Control, Spaces, App Exposé, Launchpad)
    
    func triggerMissionControl() {
        // Mission Control shortcut: Ctrl + Up Arrow
        postKeyboardShortcut(keyCode: 126, modifiers: [.maskControl])
    }
    
    func triggerAppExpose() {
        // App Exposé shortcut: Ctrl + Down Arrow
        postKeyboardShortcut(keyCode: 125, modifiers: [.maskControl])
    }
    
    func triggerSpacesLeft() {
        // Move Left a Space: Ctrl + Left Arrow
        postKeyboardShortcut(keyCode: 123, modifiers: [.maskControl])
    }
    
    func triggerSpacesRight() {
        // Move Right a Space: Ctrl + Right Arrow
        postKeyboardShortcut(keyCode: 124, modifiers: [.maskControl])
    }

    func triggerLaunchpad() {
        let launchpadPath = "/System/Applications/Launchpad.app"
        if FileManager.default.fileExists(atPath: launchpadPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: launchpadPath))
        }
    }
    
    func zoom(scale: Double) {
        let isFiveFingerZoomEnabled = UserDefaults.standard.object(forKey: "linkos_trackpad_five_finger_zoom") as? Bool ?? true
        guard isFiveFingerZoomEnabled else { return }
        
        let diff = scale - 1.0
        accumulatedZoomScroll += diff
        accumulatedZoomScroll = min(0.1, max(-0.1, accumulatedZoomScroll))
        
        let threshold = 0.02
        if accumulatedZoomScroll >= threshold {
            postKeyboardShortcut(keyCode: 24, modifiers: [.maskCommand, .maskShift])
            accumulatedZoomScroll -= threshold
        } else if accumulatedZoomScroll <= -threshold {
            postKeyboardShortcut(keyCode: 27, modifiers: [.maskCommand])
            accumulatedZoomScroll += threshold
        }
    }

    // MARK: - Media & Special Keys

    func typeText(_ text: String) {
        for char in text.utf16 {
            var c = char
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    func pressSpecialKey(_ key: String) {
        let keyCode: CGKeyCode? = switch key.lowercaseEnclosed {
        case "backspace": 51
        case "enter": 36
        case "escape": 53
        case "tab": 48
        case "space": 49
        case "arrow_up": 126
        case "arrow_down": 125
        case "arrow_left": 123
        case "arrow_right": 124
        default: nil
        }

        if let code = keyCode {
            postKeyboardShortcut(keyCode: code, modifiers: [])
        }
    }

    func triggerMediaKey(_ key: String) {
        let systemKey: Int32? = switch key.lowercaseEnclosed {
        case "vol_up": 0 // NX_KEYTYPE_SOUND_UP
        case "vol_down": 1 // NX_KEYTYPE_SOUND_DOWN
        case "brightness_up": 2 // NX_KEYTYPE_BRIGHTNESS_UP
        case "brightness_down": 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
        case "mute": 7 // NX_KEYTYPE_MUTE
        case "play_pause": 16 // NX_KEYTYPE_PLAY
        case "next": 17 // NX_KEYTYPE_NEXT
        case "previous": 18 // NX_KEYTYPE_PREVIOUS
        default: nil
        }

        if let sk = systemKey {
            postSystemDefinedKey(key: sk)
        }
    }

    private func postSystemDefinedKey(key: Int32) {
        func ev(flags: Int32) {
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | (flags << 8)),
                data2: -1
            )
            if let sysEvent = ev?.cgEvent {
                sysEvent.post(tap: CGEventTapLocation.cghidEventTap)
            }
        }
        ev(flags: 0xA) // Key down
        ev(flags: 0xB) // Key up
    }
    
    // MARK: - Helper
    
    private func postKeyboardShortcut(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        usleep(5000) // 5ms delay to prevent modifier sticking
        up.post(tap: .cghidEventTap)
    }
}

private extension String {
    var lowercaseEnclosed: String {
        return self.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
