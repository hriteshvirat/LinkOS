import Cocoa

public enum ToolbarEdge: String, Codable, CaseIterable, Equatable, Sendable {
    case bottom
    case left
    case right
    case top

    var isVertical: Bool {
        self == .left || self == .right
    }
    
    var isHorizontal: Bool {
        !isVertical
    }
}

/// Definitive immutable geometry output from `MirroringLayoutModel`.
/// No UI component should compute its own frames; all components consume this struct.
struct MirroringLayoutGeometry: Equatable, Sendable {
    let phoneFrame: NSRect
    let toolbarFrame: NSRect
    let guideFrame: NSRect
    let interactionRegion: [NSRect]
    let popupAnchor: NSPoint
    
    /// Evaluates whether a point (in screen coordinates) intersects the unified interaction region union.
    func contains(screenPoint: NSPoint) -> Bool {
        for rect in interactionRegion {
            if rect.contains(screenPoint) {
                return true
            }
        }
        return false
    }
}

/// Pure immutable geometry calculator for phone mirroring layouts.
/// Decoupled from AppKit state and video rendering loops.
struct MirroringLayoutModel: Sendable {
    let phoneFrame: NSRect
    let toolbarEdge: ToolbarEdge
    let isFloating: Bool
    let floatingToolbarFrame: NSRect
    let popupFrame: NSRect?
    let relativeY: CGFloat
    
    /// Dynamic toolbar thickness scaling based on phone window width.
    static func toolbarThickness(for phoneFrame: NSRect) -> CGFloat {
        return 52.0
    }
    
    /// Gap between phone window edge and toolbar panel.
    private static let toolbarGap: CGFloat = 8.0
    
    init(
        phoneFrame: NSRect,
        toolbarEdge: ToolbarEdge,
        isFloating: Bool = false,
        floatingToolbarFrame: NSRect = .zero,
        popupFrame: NSRect? = nil,
        relativeY: CGFloat = 0.5
    ) {
        self.phoneFrame = phoneFrame
        self.toolbarEdge = toolbarEdge
        self.isFloating = isFloating
        self.floatingToolbarFrame = floatingToolbarFrame
        self.popupFrame = popupFrame
        self.relativeY = relativeY
    }
    
    /// Toolbar capsule size: fixed 220pt pill on vertical edges (sliding capsule), full phone width exactly on horizontal edges.
    static func proportionalToolbarSize(for edge: ToolbarEdge, phoneFrame: NSRect) -> NSSize {
        let thickness = toolbarThickness(for: phoneFrame)
        let length = phoneFrame.isValidWindowFrame && phoneFrame.width > 0 ? phoneFrame.width : 260.0
        if edge.isVertical {
            return NSSize(width: thickness, height: length)
        } else {
            return NSSize(width: length, height: thickness)
        }
    }
    
    /// Computes the definitive layout geometry based on current state parameters.
    func calculate() -> MirroringLayoutGeometry {
        // 1. Calculate Docked Frame (bar spans entire phone edge, no sliding offset)
        let dockedFrame = Self.dockedFrame(for: toolbarEdge, phoneFrame: phoneFrame, relativeY: relativeY)
        
        // 2. Calculate Toolbar Frame (floating uses floating origin, otherwise docked)
        let toolbarFrame: NSRect
        if isFloating {
            toolbarFrame = floatingToolbarFrame.isValidWindowFrame ? floatingToolbarFrame : dockedFrame
        } else {
            toolbarFrame = dockedFrame
        }
        
        // 3. Calculate Popover Anchor
        let popupAnchor: NSPoint
        switch toolbarEdge {
        case .bottom:
            popupAnchor = NSPoint(x: toolbarFrame.midX, y: toolbarFrame.maxY)
        case .top:
            popupAnchor = NSPoint(x: toolbarFrame.midX, y: toolbarFrame.minY)
        case .left:
            popupAnchor = NSPoint(x: toolbarFrame.maxX, y: toolbarFrame.midY)
        case .right:
            popupAnchor = NSPoint(x: toolbarFrame.minX, y: toolbarFrame.midY)
        }
        
        // 4. Build Union of Interaction Region
        var region: [NSRect] = []
        if phoneFrame.isValidWindowFrame && phoneFrame.width > 0 && phoneFrame.height > 0 {
            region.append(phoneFrame.insetBy(dx: -2, dy: -2))
        }
        if toolbarFrame.isValidWindowFrame && toolbarFrame.width > 0 && toolbarFrame.height > 0 {
            region.append(toolbarFrame.insetBy(dx: -4, dy: -4))
        }
        if dockedFrame.isValidWindowFrame && dockedFrame.width > 0 && dockedFrame.height > 0 && dockedFrame != toolbarFrame {
            region.append(dockedFrame)
        }
        if let pf = popupFrame, pf.isValidWindowFrame && pf.width > 0 && pf.height > 0 {
            region.append(pf.insetBy(dx: -4, dy: -4))
        }
        
        return MirroringLayoutGeometry(
            phoneFrame: phoneFrame,
            toolbarFrame: toolbarFrame,
            guideFrame: dockedFrame,
            interactionRegion: region,
            popupAnchor: popupAnchor
        )
    }
    
    static func dockedFrame(for edge: ToolbarEdge, phoneFrame: NSRect, relativeY: CGFloat = 0.5) -> NSRect {
        let thickness = toolbarThickness(for: phoneFrame)
        let fixedLength = phoneFrame.isValidWindowFrame && phoneFrame.width > 0 ? phoneFrame.width : 260.0
        
        guard phoneFrame.isValidWindowFrame else {
            return NSRect(x: 100, y: 100, width: fixedLength, height: thickness)
        }
        
        switch edge {
        case .bottom:
            return NSRect(
                x: phoneFrame.minX,
                y: phoneFrame.minY - thickness - toolbarGap,
                width: phoneFrame.width,
                height: thickness
            )
        case .top:
            return NSRect(
                x: phoneFrame.minX,
                y: phoneFrame.maxY + toolbarGap,
                width: phoneFrame.width,
                height: thickness
            )
        case .left:
            let minYBound = phoneFrame.minY + fixedLength / 2.0
            let maxYBound = phoneFrame.maxY - fixedLength / 2.0
            let targetY   = phoneFrame.minY + (phoneFrame.height * relativeY)
            let clampedY  = max(minYBound, min(maxYBound, targetY))
            return NSRect(
                x: phoneFrame.minX - thickness - toolbarGap,
                y: clampedY - fixedLength / 2.0,
                width: thickness,
                height: fixedLength
            )
        case .right:
            let minYBound = phoneFrame.minY + fixedLength / 2.0
            let maxYBound = phoneFrame.maxY - fixedLength / 2.0
            let targetY   = phoneFrame.minY + (phoneFrame.height * relativeY)
            let clampedY  = max(minYBound, min(maxYBound, targetY))
            return NSRect(
                x: phoneFrame.maxX + toolbarGap,
                y: clampedY - fixedLength / 2.0,
                width: thickness,
                height: fixedLength
            )
        }
    }
}
