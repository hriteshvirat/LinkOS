import Cocoa
import SwiftUI
import Combine

// ToolbarEdge definition moved to MirroringLayoutModel.swift to ensure centralized layout rules

// MARK: - PhoneToolbarPanel

/// A borderless, non-activating NSPanel that floats along any of the 4 edges of the phone mirroring window.
/// Supports magnetic snap docking when dragged near an edge.
/// Never steals focus from the phone window.
final class PhoneToolbarPanel: NSPanel {

    // MARK: - Layout Constants
    // barThickness must match MirroringLayoutModel.toolbarThickness
    private let barThickness: CGFloat       = 52
    private let snapRadius: CGFloat         = 100   // Distance to trigger snap
    private let unsnapRadius: CGFloat       = 150   // Distance to release snap (hysteresis)
    private let hideDelay: TimeInterval     = 3.00
    private let animDuration: TimeInterval  = 0.25

    // MARK: - State
    private weak var phoneWindow: NSWindow?
    private var hideWorkItem: DispatchWorkItem?
    private var isMouseInsidePanel = false
    private var cancellables = Set<AnyCancellable>()
    private var shouldAnimateNextFrame = false

    // Use MirroringWorkspace for UI states

    // Drag state
    private var isDragging = false
    private var isSnapped  = true   // Start snapped to initial docked edge
    private var dragMonitor: Any?   // Global NSEvent monitor active only during a drag
    
    private var dragTimer: Timer?
    private var dragApproved = false
    private var initialMouseScreenLoc = NSPoint.zero
    private var initialWindowFrame = NSRect.zero
    private var activeTouchCount = 0
    
    private var localDragMonitor: Any?
    private var globalDragMonitor: Any?
    private var localMouseUpMonitor: Any?
    private var globalMouseUpMonitor: Any?

    // MARK: - Init

    init(attachedTo phoneWindow: NSWindow) {
        self.phoneWindow = phoneWindow
        
        let initialFrame = phoneWindow.frame
        let defaultThickness = MirroringLayoutModel.toolbarThickness(for: initialFrame)
        
        super.init(
            contentRect: NSRect(x: 100, y: 100, width: 220, height: defaultThickness),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.hasShadow = false
        self.alphaValue = 0
        self.ignoresMouseEvents = false
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.isMovableByWindowBackground = false
        
        setupContent()
        setupPanelTracking()
        observePhoneWindow(phoneWindow)
        setupDragToSnap()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    private func setupContent() {
        rebuildContent()
        MirroringWorkspace.shared.$dockState
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if self?.isDragging == false {
                    self?.shouldAnimateNextFrame = true
                    self?.repositionPanel()
                }
            }
            .store(in: &cancellables)
            
        MirroringWorkspace.shared.$showControlsPopover
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                if show {
                    self?.cancelHide()
                } else {
                    self?.scheduleHide()
                }
            }
            .store(in: &cancellables)
            
        NotificationCenter.default.publisher(for: .mirroringLayoutDidUpdate)
            .sink { [weak self] notif in
                guard let self = self,
                      let geometry = notif.object as? MirroringLayoutGeometry,
                      geometry.toolbarFrame.isValidWindowFrame,
                      self.isDragging == false else {
                    // During drag, if we receive a layout update it's because the edge changed.
                    // Animate the resize for smooth orientation rotation.
                    if let self = self,
                       let geometry = notif.object as? MirroringLayoutGeometry,
                       geometry.toolbarFrame.isValidWindowFrame,
                       self.isDragging {
                        NSAnimationContext.runAnimationGroup { ctx in
                            ctx.duration = 0.15
                            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                            self.animator().setFrame(geometry.toolbarFrame, display: true)
                        }
                    }
                    return
                }
                
                if self.shouldAnimateNextFrame {
                    self.shouldAnimateNextFrame = false
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        self.animator().setFrame(geometry.toolbarFrame, display: true)
                    }
                } else {
                    self.setFrame(geometry.toolbarFrame, display: true)
                }
            }
            .store(in: &cancellables)

        // During drag: update origin only, no full layout pass.
        NotificationCenter.default.publisher(for: .mirroringToolbarOriginChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notif in
                guard let self = self, self.isDragging, let origin = notif.object as? NSPoint else { return }
                var f = self.frame
                f.origin = origin
                if f.isValidWindowFrame {
                    self.setFrame(f, display: true)
                }
            }
            .store(in: &cancellables)

        // Observe active session mirror state to show panel.
        // User requested that the toolbar appear always, even during connection/pairing.
        PhoneSessionManager.shared.$activeSession
            .flatMap { $0.$mirrorState }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                self.showImmediately()
            }
            .store(in: &cancellables)
    }

    private func rebuildContent() {
        let bar = PhoneBottomBar(
            session: PhoneSessionManager.shared.activeSession
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let host = PhoneToolbarHostingView(rootView: bar)
        host.wantsLayer = true
        host.onTouchesChanged = { [weak self] count in
            self?.activeTouchCount = count
            if count == 3 {
                self?.dragApproved = true
                self?.isDragging = true
                self?.dragStartFrame = self?.frame ?? .zero
            }
        }
        contentView = host
    }

    // MARK: - Panel-level Tracking Area

    private func setupPanelTracking() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let cv = self.contentView else { return }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            cv.addTrackingArea(area)
        }
    }

    // MARK: - Drag-to-Snap (Native OS Drag with Notification-based Snapping)
    //
    // The grab handle View calls `window.performDrag` to invoke AppKit's native window
    // dragging loop. This runs at a hardware-accelerated 120 FPS with zero cursor lag.
    //
    // While the user drags, we listen to NSWindow.didMoveNotification to evaluate the
    // nearest docking edge, rendering a curved white outline highlight.
    // When the mouse is released, we snap the toolbar panel to the target edge.

    private func setupDragToSnap() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self = self, let win = event.window, win === self else { return event }
            
            // Record initial position, but do not start dragging unconditionally.
            // Dragging only actually occurs if approved (e.g. 3-finger touch).
            self.initialMouseScreenLoc = NSEvent.mouseLocation
            self.initialWindowFrame = self.frame
            return event
        }
        
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
            guard let self = self else { return event }
            
            if !self.isDragging {
                if self.dragApproved || self.activeTouchCount == 3 {
                    self.isDragging = true
                    NSCursor.closedHand.set()
                    MirroringWorkspace.shared.showControlsPopover = false
                } else {
                    return event
                }
            }
            
            self.handleMouseDragged(event)
            return event
        }
        
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            self.dragApproved = false
            if self.isDragging {
                self.isDragging = false
                NSCursor.arrow.set()
                self.handleDragEnded()
            }
            return event
        }
    }
    
    private var dragStartFrame = NSRect.zero

    private func handleMouseDragged(_ event: NSEvent) {
        let mouseLoc = NSEvent.mouseLocation
        let dx = mouseLoc.x - initialMouseScreenLoc.x
        let dy = mouseLoc.y - initialMouseScreenLoc.y
        
        guard let phone = phoneWindow else { return }
        let pf = phone.frame
        
        let currentCenter = NSPoint(x: initialWindowFrame.midX + dx, y: initialWindowFrame.midY + dy)
        let nearestEdge = nearestValidEdge(from: currentCenter, phoneFrame: pf)
        
        let targetSize = MirroringLayoutModel.proportionalToolbarSize(for: nearestEdge, phoneFrame: pf)
        
        var newFrame = NSRect(
            x: currentCenter.x - targetSize.width / 2.0,
            y: currentCenter.y - targetSize.height / 2.0,
            width: targetSize.width,
            height: targetSize.height
        )
        
        self.setFrame(newFrame, display: true)
        
        // Prepare SwiftUI toolbar orientation layout in advance
        MirroringWorkspace.shared.approachingEdge = nearestEdge
        MirroringWorkspace.shared.dockState = .previewing(for: nearestEdge)
        
        // Display white curved outline preview highlight
        showDockPreview(edge: nearestEdge, phoneFrame: pf, draggingFrame: newFrame)
    }

    private func handleDragEnded() {
        hideDockPreview()
        
        guard let phone = phoneWindow else { return }
        let panelCenter = NSPoint(x: self.frame.midX, y: self.frame.midY)
        let pf = phone.frame
        
        let nearestEdge = nearestValidEdge(from: panelCenter, phoneFrame: pf)
        
        if nearestEdge.isVertical {
            let relY = (panelCenter.y - pf.minY) / pf.height
            MirroringWorkspace.shared.relativeY = max(0.0, min(1.0, relY))
        }
        
        MirroringWorkspace.shared.activeToolbarEdge = nearestEdge
        MirroringWorkspace.shared.approachingEdge = nil
        MirroringWorkspace.shared.dockState = .docked(for: nearestEdge)
        UserDefaults.standard.set(nearestEdge.rawValue, forKey: "pm_toolbar_edge")
        isSnapped = true
        
        MirroringLayoutCoordinator.shared.notifyDockEdgeChanged(to: nearestEdge)
    }
    
    private func nearestValidEdge(from point: NSPoint, phoneFrame pf: NSRect) -> ToolbarEdge {
        let bottomLine = pf.minY + (pf.height * 0.15)
        let centerX = pf.midX
        
        if point.y < bottomLine {
            return .bottom
        } else if point.x < centerX {
            return .left
        } else {
            return .right
        }
    }
    
    // MARK: - Native Single-Layer Dock Preview Indicator
    
    private var leftPreview: NSWindow?
    private var rightPreview: NSWindow?
    private var bottomPreview: NSWindow?
    
    private func createPreviewWindow() -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .floating
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.cornerRadius = 24.0
        win.contentView?.layer?.borderWidth = 2.0
        win.contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        win.contentView?.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        return win
    }
    
    private func showDockPreview(edge: ToolbarEdge, phoneFrame: NSRect, draggingFrame: NSRect) {
        if leftPreview == nil { leftPreview = createPreviewWindow() }
        if rightPreview == nil { rightPreview = createPreviewWindow() }
        if bottomPreview == nil { bottomPreview = createPreviewWindow() }
        
        let mouseLoc = NSEvent.mouseLocation
        let relY = max(0.0, min(1.0, (mouseLoc.y - phoneFrame.minY) / phoneFrame.height))
        
        let edges: [(ToolbarEdge, NSWindow?)] = [(.left, leftPreview), (.right, rightPreview), (.bottom, bottomPreview)]
        
        for (e, preview) in edges {
            guard let preview = preview else { continue }
            let targetFrame = MirroringLayoutModel.dockedFrame(for: e, phoneFrame: phoneFrame, relativeY: relY)
            if targetFrame.isValidWindowFrame {
                preview.setFrame(targetFrame, display: true)
                let isActive = (e == edge)
                preview.contentView?.layer?.borderColor = NSColor.white.withAlphaComponent(isActive ? 0.85 : 0.2).cgColor
                preview.contentView?.layer?.backgroundColor = NSColor.white.withAlphaComponent(isActive ? 0.15 : 0.05).cgColor
                
                if !preview.isVisible {
                    preview.alphaValue = 1.0
                    preview.orderFront(nil)
                }
            }
        }
    }
    
    private func hideDockPreview() {
        leftPreview?.alphaValue = 0.0
        leftPreview?.orderOut(nil)
        rightPreview?.alphaValue = 0.0
        rightPreview?.orderOut(nil)
        bottomPreview?.alphaValue = 0.0
        bottomPreview?.orderOut(nil)
    }


    private func distanceToEdge(_ edge: ToolbarEdge, from mouseLoc: NSPoint, phoneFrame pf: NSRect) -> CGFloat {
        switch edge {
        case .bottom: return abs(mouseLoc.y - pf.minY)
        case .top:    return abs(mouseLoc.y - pf.maxY)
        case .left:   return abs(mouseLoc.x - pf.minX)
        case .right:  return abs(mouseLoc.x - pf.maxX)
        }
    }

    // MARK: - Window Notifications

    private func observePhoneWindow(_ phoneWindow: NSWindow) {
        let center = NotificationCenter.default

        for name in [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            center.publisher(for: name, object: phoneWindow)
            .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.forceHide() }
                .store(in: &cancellables)
        }

        center.publisher(for: NSWindow.didDeminiaturizeNotification, object: phoneWindow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionPanel() }
            .store(in: &cancellables)

        center.publisher(for: NSWindow.didEnterFullScreenNotification, object: phoneWindow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.forceHide() }
            .store(in: &cancellables)

        center.publisher(for: NSWindow.didExitFullScreenNotification, object: phoneWindow)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionPanel() }
            .store(in: &cancellables)

        center.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.forceHide() }
            .store(in: &cancellables)

        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.repositionPanel() }
            .store(in: &cancellables)
    }

    // MARK: - Positioning

    /// Returns the exact NSRect for the toolbar from the layout model single source of truth.
    func frameForEdge(_ edge: ToolbarEdge, phoneFrame pf: NSRect) -> NSRect {
        guard pf.isValidWindowFrame else {
            LinkOSLogger.shared.error("[PhoneToolbarPanel] frameForEdge invoked with invalid phoneFrame: \(pf)", category: .media)
            return NSRect(x: 100, y: 100, width: 200, height: barThickness)
        }
        return MirroringLayoutModel.dockedFrame(for: edge, phoneFrame: pf, relativeY: MirroringWorkspace.shared.relativeY)
    }

    func repositionPanel(animate: Bool = false) {
        guard !isDragging,
              let phone = phoneWindow,
              phone.isVisible,
              !phone.isMiniaturized else { return }
        
        MirroringLayoutCoordinator.shared.notifyWindowGeometryChanged(phoneFrame: phone.frame)
    }

    /// Immediately reveals and attaches the toolbar panel as a child of the phone window.
    func showImmediately() {
        cancelHide()
        repositionPanel()
        if let parent = phoneWindow, !(parent.childWindows?.contains(self) ?? false) {
            parent.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFront(nil) }
        contentView?.layer?.removeAllAnimations()
        alphaValue = 1.0
        scheduleHide()
    }

    // MARK: - Show / Hide

    private func isMirroringActive() -> Bool {
        return true // User requested toolbar to always show
    }

    func revealPanel() {
        guard isMirroringActive() else { return }
        isMouseInsidePanel = true
        cancelHide()
        showPanel()
    }
    
    private var lastPingTime: Date = .distantPast
    
    func pingToolbar() {
        guard isMirroringActive() else { return }
        let now = Date()
        if alphaValue < 0.95 {
            showPanel()
        }
        if !isMouseInsidePanel && !MirroringWorkspace.shared.showControlsPopover {
            // Only restart timer if more than 0.5s has elapsed since last ping to prevent UI thread thrashing
            if now.timeIntervalSince(lastPingTime) > 0.5 || hideWorkItem == nil {
                lastPingTime = now
                scheduleHide()
            }
        }
    }

    func panelMouseExited() {
        isMouseInsidePanel = false
        scheduleHide()
    }

    private func showPanel() {
        guard isMirroringActive() else { return }
        cancelHide()
        repositionPanel()
        if let parent = phoneWindow, !(parent.childWindows?.contains(self) ?? false) {
            parent.addChildWindow(self, ordered: .above)
        }
        if !isVisible { orderFront(nil) }

        if alphaValue < 0.95 {
            contentView?.layer?.removeAllAnimations()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = animDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1.0
            }
        }
    }

    private func scheduleHide() {
        guard !isMouseInsidePanel && !MirroringWorkspace.shared.showControlsPopover else { return }
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isMouseInsidePanel, !MirroringWorkspace.shared.showControlsPopover else { return }
            self.hidePanel()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }

    private func hidePanel() {
        guard !isMouseInsidePanel && !MirroringWorkspace.shared.showControlsPopover else { return }
        contentView?.layer?.removeAllAnimations()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0.02
        }, completionHandler: {
        })
    }

    func forceHide() {
        cancelHide()
        isMouseInsidePanel = false
        contentView?.layer?.removeAllAnimations()
        alphaValue = 0
        orderOut(nil)
    }

    private func cancelHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    override func mouseEntered(with event: NSEvent) {
        revealPanel()
    }

    override func mouseExited(with event: NSEvent) {
        panelMouseExited()
    }

    // MARK: - Responder Status (Must be true for popover controls and menus to be clickable)
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Comparable.clamped helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
    
    func clamped(min minVal: Self, max maxVal: Self) -> Self {
        let lower = min(minVal, maxVal)
        let upper = max(minVal, maxVal)
        return min(max(self, lower), upper)
    }
}

// MARK: - PhoneToolbarHostingView

class PhoneToolbarHostingView<Content: View>: NSHostingView<Content> {
    var onTouchesChanged: ((Int) -> Void)?
    
    @MainActor @preconcurrency required public init(rootView: Content) {
        super.init(rootView: rootView)
        self.acceptsTouchEvents = true
    }
    
    @MainActor @preconcurrency required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        let count = event.touches(matching: .touching, in: self).count
        onTouchesChanged?(count)
    }
    
    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        let count = event.touches(matching: .touching, in: self).count
        onTouchesChanged?(count)
    }
    
    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        let count = event.touches(matching: .touching, in: self).count
        onTouchesChanged?(count)
    }
    
    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        let count = event.touches(matching: .touching, in: self).count
        onTouchesChanged?(count)
    }
}
