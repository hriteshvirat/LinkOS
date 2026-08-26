import Cocoa
import Carbon

@MainActor
final class PhoneInputService {
    static let shared = PhoneInputService()
    
    private var isDragging = false
    private var dragStart = CGPoint.zero
    private var lastDragTime: Date = Date()
    private var lastHoverTime: Date = Date.distantPast  // Throttle hover to ~60fps
    private var mouseDownTime: Date = Date()
    private var didExceedDragThreshold = false
    
    // Launcher Swipe State
    private var accumulatedScrollDeltaX: Float = 0
    private var accumulatedScrollDeltaY: Float = 0
    private var hasFiredLauncherSwipe = false
    private var launcherScrollResetTimer: DispatchWorkItem?
    
    // Momentum Normalization State
    private var lastScrollSentTime: Date = Date.distantPast
    private var accumulatedMomentumX: Float = 0
    private var accumulatedMomentumY: Float = 0
    private var scrollEndTimer: DispatchWorkItem?
    
    private init() {}
    
    private var isScrolling = false

    func handleMouseMoved(at location: CGPoint, viewSize: CGSize) {
        if isScrolling {
            isScrolling = false // Self-correct scroll lock state if user starts active mouse hover movement
        }
        let now = Date()
        guard now.timeIntervalSince(lastHoverTime) >= (1.0 / 120.0) else { return }
        lastHoverTime = now
        let norm = normalize(location, size: viewSize)
        PhoneSessionManager.shared.activeSession.sendHover(x: Float(norm.x), y: Float(norm.y))
    }
    
    func handleMouseDown(at location: CGPoint, viewSize: CGSize, clickCount: Int = 1) {
        let norm = normalize(location, size: viewSize)
        isDragging = true
        dragStart = norm
        lastDragTime = Date()
        mouseDownTime = Date()
        didExceedDragThreshold = false
    }
    
    func handleMouseDragged(to location: CGPoint, viewSize: CGSize) {
        guard isDragging else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDragTime) >= (1.0 / 120.0) else { return }
        lastDragTime = now
        
        let norm = normalize(location, size: viewSize)
        
        let dragThreshold: CGFloat = 8.0
        let dx = (norm.x - dragStart.x) * viewSize.width
        let dy = (norm.y - dragStart.y) * viewSize.height
        let dist = sqrt(dx*dx + dy*dy)
        
        if dist > dragThreshold {
            didExceedDragThreshold = true
        }
    }
    
    func handleMouseUp(at location: CGPoint, viewSize: CGSize, clickCount: Int = 1) {
        guard isDragging else { return }
        let norm = normalize(location, size: viewSize)
        
        let now = Date()
        let totalDurationMs = Int(now.timeIntervalSince(mouseDownTime) * 1000)
        
        if !didExceedDragThreshold && totalDurationMs < 350 {
            // Treat as atomic Click
            PhoneSessionManager.shared.activeSession.sendClick(x: Float(norm.x), y: Float(norm.y))
        } else {
            // Complete drag sequence using DRAG command
            let duration = max(100, totalDurationMs)
            PhoneSessionManager.shared.activeSession.sendDrag(
                startX: Float(dragStart.x), startY: Float(dragStart.y),
                endX: Float(norm.x), endY: Float(norm.y),
                duration: duration
            )
        }
        isDragging = false
    }
    
    func resetInputState() {
        isDragging = false
        didExceedDragThreshold = false
        lastDragTime = Date()
        lastHoverTime = Date.distantPast
        isScrolling = false
    }
    
    func handleScroll(at location: CGPoint, event: NSEvent, viewSize: CGSize) {
        let norm = normalize(location, size: viewSize)
        
        // Cancel active mouse drag immediately to avoid conflict between scrolling and click-and-hold states
        if isDragging {
            isDragging = false
        }

        // Handle scroll phase updates to freeze/unfreeze cursor
        if event.phase == .began {
            isScrolling = true
        } else if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            isScrolling = false
        }
        
        let rawDeltaY = Float(event.scrollingDeltaY)
        let rawDeltaX = Float(event.scrollingDeltaX)
        guard abs(rawDeltaY) > 0.001 || abs(rawDeltaX) > 0.001 else { return }
        
        // Launcher navigation: translate scrolls to continuous swipe drags
        if PhoneSessionManager.shared.activeSession.activeAppCategory == "launcher" {
            // Ignore trackpad momentum completely on the launcher
            guard event.momentumPhase == .none else { return }
            
            if event.phase == .began {
                accumulatedScrollDeltaX = 0
                accumulatedScrollDeltaY = 0
                hasFiredLauncherSwipe = false
            }
            
            if event.phase == .ended || event.phase == .cancelled {
                hasFiredLauncherSwipe = false
                accumulatedScrollDeltaX = 0
                accumulatedScrollDeltaY = 0
            }
            
            // Mouse wheel fallback: use a debounce timer to reset swipe state
            if event.phase == .none {
                launcherScrollResetTimer?.cancel()
                let resetWorkItem = DispatchWorkItem { [weak self] in
                    self?.hasFiredLauncherSwipe = false
                    self?.accumulatedScrollDeltaX = 0
                    self?.accumulatedScrollDeltaY = 0
                }
                launcherScrollResetTimer = resetWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: resetWorkItem)
            }
            
            if !hasFiredLauncherSwipe {
                accumulatedScrollDeltaX += rawDeltaX
                accumulatedScrollDeltaY += rawDeltaY
                
                let threshold: Float = 20.0
                if abs(accumulatedScrollDeltaX) > threshold && abs(accumulatedScrollDeltaX) > abs(accumulatedScrollDeltaY) {
                    hasFiredLauncherSwipe = true
                    let direction: Float = accumulatedScrollDeltaX > 0 ? 1.0 : -1.0
                    let startX = 0.5 - (direction * 0.45)
                    let endX = 0.5 + (direction * 0.45)
                    PhoneSessionManager.shared.activeSession.sendDrag(
                        startX: Float(startX), startY: 0.5,
                        endX: Float(endX), endY: 0.5,
                        duration: 150
                    )
                } else if abs(accumulatedScrollDeltaY) > threshold && abs(accumulatedScrollDeltaY) > abs(accumulatedScrollDeltaX) {
                    hasFiredLauncherSwipe = true
                    let direction: Float = accumulatedScrollDeltaY > 0 ? 1.0 : -1.0
                    let startY = 0.5 + (direction * 0.45)
                    let endY = 0.5 - (direction * 0.45)
                    PhoneSessionManager.shared.activeSession.sendDrag(
                        startX: 0.5, startY: Float(startY),
                        endX: 0.5, endY: Float(endY),
                        duration: 150
                    )
                }
            }
            return // Consume launcher navigation scroll
        }
        
        // App list natural inertial scroll tuning:
        // Sensitivity scale: 0.04 (faster response)
        // Momentum damping: 0.55 (longer glide)
        // Throttle momentum: 50ms min interval (down from 33ms)
        let sensitivityScale: Float = event.hasPreciseScrollingDeltas ? 0.04 : 0.18
        let maxDeltaPerFrame: Float = 2.5
        
        var phase: String
        let isMomentum: Bool
        
        if event.momentumPhase == .began || event.momentumPhase == .changed {
            phase = "MOMENTUM"
            isMomentum = true
        } else if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            phase = "ENDED"
            isMomentum = true
            isScrolling = false
        } else if event.phase == .began {
            phase = "BEGAN"
            isMomentum = false
            isScrolling = true
        } else if event.phase == .ended || event.phase == .cancelled {
            phase = "ENDED"
            isMomentum = false
            isScrolling = false
        } else {
            phase = "CHANGED"
            isMomentum = false
        }
        
        let deltaX: Float
        let deltaY: Float
        let now = Date()
        
        if isMomentum {
            // Damping factor: 0.55
            accumulatedMomentumX += rawDeltaX * sensitivityScale * 0.55
            accumulatedMomentumY += rawDeltaY * sensitivityScale * 0.55
            
            // Throttle to 20Hz (50ms interval) to reduce message flood
            if now.timeIntervalSince(lastScrollSentTime) < 0.050 || (abs(accumulatedMomentumX) < 0.15 && abs(accumulatedMomentumY) < 0.15) {
                if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
                    accumulatedMomentumX = 0
                    accumulatedMomentumY = 0
                }
                return
            }
            deltaX = max(-maxDeltaPerFrame, min(maxDeltaPerFrame, accumulatedMomentumX))
            deltaY = max(-maxDeltaPerFrame, min(maxDeltaPerFrame, accumulatedMomentumY))
            accumulatedMomentumX = 0
            accumulatedMomentumY = 0
            lastScrollSentTime = now
        } else {
            deltaX = max(-maxDeltaPerFrame, min(maxDeltaPerFrame, rawDeltaX * sensitivityScale))
            deltaY = max(-maxDeltaPerFrame, min(maxDeltaPerFrame, rawDeltaY * sensitivityScale))
            accumulatedMomentumX = 0
            accumulatedMomentumY = 0
            lastScrollSentTime = now
        }
        
        if abs(deltaX) < 0.01 && abs(deltaY) < 0.01 && phase != "ENDED" && phase != "BEGAN" { return }
        let velocity = sqrt(deltaX * deltaX + deltaY * deltaY)
        
        let rotation = PhoneSessionManager.shared.activeSession.displayRotation
        var rotatedDeltaX = deltaX
        var rotatedDeltaY = deltaY
        if rotation == 90 {
            rotatedDeltaX = deltaY
            rotatedDeltaY = -deltaX
        } else if rotation == 180 {
            rotatedDeltaX = -deltaX
            rotatedDeltaY = -deltaY
        } else if rotation == 270 {
            rotatedDeltaX = -deltaY
            rotatedDeltaY = deltaX
        }
        
        // Debounce & schedule scroll cleanup
        scrollEndTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Task {
                await PhoneSessionManager.shared.activeSession.sendControlMessage([
                    "action": "GESTURE_STREAM",
                    "gestureType": "SCROLL",
                    "phase": "ENDED",
                    "normX": Float(norm.x),
                    "normY": Float(norm.y),
                    "deltaX": 0.0,
                    "deltaY": 0.0,
                    "velocity": 0.0,
                    "momentum": false,
                    "timestamp": event.timestamp
                ])
            }
        }
        scrollEndTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: timer)
        
        Task { await PhoneSessionManager.shared.activeSession.sendControlMessage([
            "action": "GESTURE_STREAM",
            "gestureType": "SCROLL",
            "phase": phase,
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "deltaX": rotatedDeltaX,
            "deltaY": rotatedDeltaY,
            "velocity": velocity,
            "momentum": isMomentum,
            "timestamp": event.timestamp
        ]) }
    }
    
    func handleMagnify(at location: CGPoint, event: NSEvent, viewSize: CGSize) {
        let norm = normalize(location, size: viewSize)
        let scale = 1.0 + Float(event.magnification)
        let phase = event.phase == .began ? "BEGAN" : (event.phase == .ended ? "ENDED" : "CHANGED")
        Task { await PhoneSessionManager.shared.activeSession.sendControlMessage([
            "action": "GESTURE_STREAM",
            "gestureType": "PINCH",
            "phase": phase,
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "scale": scale,
            "timestamp": event.timestamp
        ]) }
    }
    
    func handleRotate(at location: CGPoint, event: NSEvent, viewSize: CGSize) {
        let norm = normalize(location, size: viewSize)
        let phase = event.phase == .began ? "BEGAN" : (event.phase == .ended ? "ENDED" : "CHANGED")
        Task { await PhoneSessionManager.shared.activeSession.sendControlMessage([
            "action": "GESTURE_STREAM",
            "gestureType": "ROTATE",
            "phase": phase,
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "rotation": Float(event.rotation),
            "timestamp": event.timestamp
        ]) }
    }
    
    func handleSwipe(at location: CGPoint, event: NSEvent, viewSize: CGSize) {
        let norm = normalize(location, size: viewSize)
        Task { await PhoneSessionManager.shared.activeSession.sendControlMessage([
            "action": "GESTURE_STREAM",
            "gestureType": "SWIPE",
            "phase": "CHANGED",
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "deltaX": Float(event.deltaX),
            "deltaY": Float(event.deltaY),
            "timestamp": event.timestamp
        ]) }
    }
    
    func handlePressureChange(at location: CGPoint, event: NSEvent, viewSize: CGSize) {
        let norm = normalize(location, size: viewSize)
        Task { await PhoneSessionManager.shared.activeSession.sendControlMessage([
            "action": "GESTURE_STREAM",
            "gestureType": "PRESSURE",
            "phase": "CHANGED",
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "pressure": Float(event.pressure),
            "timestamp": event.timestamp
        ]) }
    }
    
    func handleKeyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        
        // Translate standard backspace and navigation keypresses
        if event.keyCode == 51 { // Backspace
            PhoneSessionManager.shared.activeSession.sendBackspace()
        } else if event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 { // Arrow keys
            // Map arrow keys or navigation events if needed, fallback to text insertion
        } else if !characters.isEmpty {
            PhoneSessionManager.shared.activeSession.sendText(characters)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Converts a view-space point to a normalized [0,1] coordinate on the Android screen.
    /// Operates in NSView point space (not backing pixels), so it is automatically
    /// correct on both Retina and non-Retina displays at any window size.
    /// Accounts for letterboxing/pillarboxing when the window aspect ratio differs from the video.
    private func normalize(_ location: CGPoint, size: CGSize) -> CGPoint {
        guard size.width > 0 && size.height > 0 && !size.width.isNaN && !size.height.isNaN else { return .zero }
        
        var renderedRect = CGRect(origin: .zero, size: size)
        let rotation = PhoneSessionManager.shared.activeSession.displayRotation
        
        if let frame = PhoneSessionManager.shared.activeSession.currentFrame, frame.height > 0, frame.width > 0 {
            let effW = (rotation == 90 || rotation == 270) ? CGFloat(frame.height) : CGFloat(frame.width)
            let effH = (rotation == 90 || rotation == 270) ? CGFloat(frame.width) : CGFloat(frame.height)
            let imageRatio = effW / effH
            let viewRatio = size.width / size.height
            
            if !imageRatio.isNaN && !viewRatio.isNaN && imageRatio > 0 {
                if viewRatio > imageRatio {
                    // Window is wider than image: black bars on left/right
                    let newWidth = size.height * imageRatio
                    renderedRect = CGRect(x: (size.width - newWidth) / 2.0, y: 0, width: newWidth, height: size.height)
                } else {
                    // Window is taller than image: black bars on top/bottom
                    let newHeight = size.width / imageRatio
                    renderedRect = CGRect(x: 0, y: (size.height - newHeight) / 2.0, width: size.width, height: newHeight)
                }
            }
        }
        
        // Uses top-left origin directly matching flipped PhoneMetalCanvasView and Android
        let x = (location.x - renderedRect.origin.x) / renderedRect.width
        let y = (location.y - renderedRect.origin.y) / renderedRect.height
        
        var finalX = x.isNaN ? 0.0 : x.coerceIn(0.0, 1.0)
        var finalY = y.isNaN ? 0.0 : y.coerceIn(0.0, 1.0)
        
        if rotation == 90 {
            let origX = finalX
            finalX = finalY
            finalY = 1.0 - origX
        } else if rotation == 180 {
            finalX = 1.0 - finalX
            finalY = 1.0 - finalY
        } else if rotation == 270 {
            let origX = finalX
            finalX = 1.0 - finalY
            finalY = origX
        }
        
        return CGPoint(x: finalX, y: finalY)
    }
}

// Swift utility extensions for value clamping
extension Float {
    func coerceIn(_ minimumValue: Float, _ maximumValue: Float) -> Float {
        return Swift.max(minimumValue, Swift.min(thisValue(), maximumValue))
    }
    private func thisValue() -> Float { return self }
}

extension CGFloat {
    func coerceIn(_ minimumValue: CGFloat, _ maximumValue: CGFloat) -> CGFloat {
        return Swift.max(minimumValue, Swift.min(self, maximumValue))
    }
}
