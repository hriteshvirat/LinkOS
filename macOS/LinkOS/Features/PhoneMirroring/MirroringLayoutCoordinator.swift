import Cocoa
import Combine
import SwiftUI

/// Coordinator managing layout updates, cursor transitions, and animations.
/// Ensures all UI components consume geometry solely from `MirroringLayoutModel`.
@MainActor
final class MirroringLayoutCoordinator: ObservableObject {
    static let shared = MirroringLayoutCoordinator()
    
    @Published private(set) var currentGeometry: MirroringLayoutGeometry = MirroringLayoutGeometry(
        phoneFrame: .zero,
        toolbarFrame: .zero,
        guideFrame: .zero,
        interactionRegion: [],
        popupAnchor: .zero
    )
    
    private var currentPhoneFrame: NSRect = .zero
    private var currentEdge: ToolbarEdge = {
        let saved = UserDefaults.standard.string(forKey: "pm_toolbar_edge") ?? ""
        if saved == "floating" { return .bottom }
        return ToolbarEdge(rawValue: saved) ?? .bottom
    }()
    private var isFloating: Bool = {
        let saved = UserDefaults.standard.string(forKey: "pm_toolbar_edge") ?? ""
        return saved == "floating"
    }()
    private var floatingFrame: NSRect = .zero
    private var popupFrame: NSRect? = nil
    
    private init() {}
    
    // MARK: - Event Triggers (Strict Rendering/Layout Decoupling)
    // Layout calculations ONLY occur upon: window resizes/moves, toolbar dragging, dock edge changes, or actual aspect ratio changes.
    // NEVER call these directly inside video frame render loops.
    
    func notifyWindowGeometryChanged(phoneFrame: NSRect) {
        guard phoneFrame.isValidWindowFrame, phoneFrame != currentPhoneFrame else { return }
        self.currentPhoneFrame = phoneFrame
        recalculateAndApply(animate: false)
    }
    
    func notifyDockEdgeChanged(to edge: ToolbarEdge) {
        self.currentEdge = edge
        self.isFloating = false
        recalculateAndApply(animate: false)
    }
    
    func notifyToolbarDragged(mouseScreenLocation: NSPoint, previewEdge: ToolbarEdge?) {
        // Legacy path — kept for compatibility. New path uses notifyToolbarSnappedDuringDrag.
        let targetEdge = previewEdge ?? currentEdge
        notifyToolbarSnappedDuringDrag(edge: targetEdge, mouseScreenLocation: mouseScreenLocation)
    }
    
    /// Positions toolbar at exact docked location for `edge` during drag (magnetic, no free-float).
    func notifyToolbarSnappedDuringDrag(edge: ToolbarEdge, mouseScreenLocation: NSPoint) {
        if edge.isVertical && currentPhoneFrame.height > 0 {
            let relY = (mouseScreenLocation.y - currentPhoneFrame.minY) / currentPhoneFrame.height
            MirroringWorkspace.shared.relativeY = max(0.0, min(1.0, relY))
        }
        
        self.isFloating = false  // Not floating — always snapped to an edge
        self.currentEdge = edge
        
        let dockedFrame = MirroringLayoutModel.dockedFrame(
            for: edge,
            phoneFrame: currentPhoneFrame,
            relativeY: MirroringWorkspace.shared.relativeY
        )
        
        let newSize = MirroringLayoutModel.proportionalToolbarSize(for: edge, phoneFrame: currentPhoneFrame)
        let edgeChanged = floatingFrame.size.width != newSize.width || floatingFrame.size.height != newSize.height
        self.floatingFrame = dockedFrame
        
        if edgeChanged {
            // Edge orientation changed — animate with fast spring for smooth rotation
            let model = MirroringLayoutModel(
                phoneFrame: currentPhoneFrame,
                toolbarEdge: edge,
                isFloating: false,
                floatingToolbarFrame: .zero,
                popupFrame: popupFrame,
                relativeY: MirroringWorkspace.shared.relativeY
            )
            let newGeometry = model.calculate()
            MirroringWorkspace.shared.toolbarPanelFrame = newGeometry.toolbarFrame
            NotificationCenter.default.post(name: .mirroringLayoutDidUpdate, object: newGeometry)
        } else {
            // Same edge — just update origin directly (performance path)
            NotificationCenter.default.post(name: .mirroringToolbarOriginChanged, object: dockedFrame.origin)
        }
    }

    func notifyToolbarFloatingDuringDrag(frame: NSRect) {
        self.isFloating = true
        self.floatingFrame = frame
        
        let model = MirroringLayoutModel(
            phoneFrame: currentPhoneFrame,
            toolbarEdge: currentEdge,
            isFloating: true,
            floatingToolbarFrame: floatingFrame,
            popupFrame: popupFrame,
            relativeY: MirroringWorkspace.shared.relativeY
        )
        let newGeometry = model.calculate()
        MirroringWorkspace.shared.toolbarPanelFrame = newGeometry.toolbarFrame
        NotificationCenter.default.post(name: .mirroringLayoutDidUpdate, object: newGeometry)
    }
    
    func commitToolbarFloatingDrag() {
        self.isFloating = true
        recalculateAndApply(animate: false)
    }

    /// Called on mouse-up after a drag ends. Runs the full geometry recalculation once.
    func commitToolbarDrag() {
        recalculateAndApply(animate: false)
    }

    func notifyPopupStateChanged(frame: NSRect?) {
        self.popupFrame = frame
        recalculateAndApply(animate: false)
    }
    
    private func recalculateAndApply(animate: Bool) {
        let model = MirroringLayoutModel(
            phoneFrame: currentPhoneFrame,
            toolbarEdge: currentEdge,
            isFloating: isFloating,
            floatingToolbarFrame: floatingFrame,
            popupFrame: popupFrame,
            relativeY: MirroringWorkspace.shared.relativeY
        )
        
        let newGeometry = model.calculate()
        self.currentGeometry = newGeometry
        
        // Notify workspace and downstream UI consumers without independent calculations
        MirroringWorkspace.shared.phoneWindowFrame = newGeometry.phoneFrame
        MirroringWorkspace.shared.toolbarPanelFrame = newGeometry.toolbarFrame
        
        // Push geometry to ToolbarPanel directly
        NotificationCenter.default.post(name: .mirroringLayoutDidUpdate, object: newGeometry)
    }
}

extension Notification.Name {
    static let mirroringLayoutDidUpdate     = Notification.Name("pm_mirroringLayoutDidUpdate")
    static let mirroringToolbarOriginChanged = Notification.Name("pm_mirroringToolbarOriginChanged")
}
