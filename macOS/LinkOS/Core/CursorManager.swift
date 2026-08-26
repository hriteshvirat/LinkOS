import Cocoa
import SwiftUI

enum CursorStyle: String, CaseIterable, Identifiable {
    case systemArrow = "System Arrow"
    case whiteCircle = "White Circle"
    case dot = "Dot"
    case crosshair = "Crosshair"
    case custom = "Custom..."
    
    var id: String { rawValue }
}

enum HotspotType: String, CaseIterable, Identifiable {
    case center = "Center"
    case topLeft = "Top Left"
    case bottomLeft = "Bottom Left"
    case custom = "Custom X/Y"
    
    var id: String { rawValue }
}

final class CursorManager: ObservableObject {
    static let shared = CursorManager()
    
    @AppStorage("pm_cursor_style") var style: CursorStyle = .whiteCircle { didSet { refresh() } }
    @AppStorage("pm_cursor_size") var size: Double = 18.0 { didSet { refresh() } }
    @AppStorage("pm_cursor_opacity") var opacity: Double = 0.85 { didSet { refresh() } }
    @AppStorage("pm_cursor_shadow") var shadow: Bool = true { didSet { refresh() } }
    @AppStorage("pm_cursor_outline") var outline: Bool = true { didSet { refresh() } }
    @AppStorage("pm_cursor_glow") var glow: Bool = false { didSet { refresh() } }
    @AppStorage("pm_cursor_tint") var tintHex: String = "#FFFFFF" { didSet { refresh() } }
    @AppStorage("pm_cursor_rotation") var rotation: Double = 0.0 { didSet { refresh() } }
    @AppStorage("pm_cursor_hotspot_type") var hotspotType: HotspotType = .center { didSet { refresh() } }
    @AppStorage("pm_cursor_hotspot_x") var hotspotX: Double = 0.5 { didSet { refresh() } }
    @AppStorage("pm_cursor_hotspot_y") var hotspotY: Double = 0.5 { didSet { refresh() } }
    @AppStorage("pm_cursor_custom_path") var customPath: String = "" { didSet { refresh() } }
    @Published var activeCursor: NSCursor?
    
    private var cachedCustomPath: String?
    private var cachedCustomImage: NSImage?
    
    private init() {
        updateCursor()
    }
    
    func refresh() {
        updateCursor()
    }
    
    private func updateCursor() {
        if style == .systemArrow {
            activeCursor = nil // Use default
            return
        }
        
        let side = CGFloat(size)
        let rect = NSRect(x: 0, y: 0, width: side, height: side)
        
        // Ensure custom image is only decoded once
        if style == .custom {
            if cachedCustomPath != customPath {
                cachedCustomImage = NSImage(contentsOfFile: customPath)
                cachedCustomPath = customPath
            }
        }
        
        var hex = tintHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.remove(at: hex.startIndex) }
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        let tint = (hex.count == 6) ? NSColor(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        ) : .white
        
        // Modern block-based NSImage constructor: automatically generates resolution-independent representations
        let image = NSImage(size: rect.size, flipped: false) { drawRect in
            guard let cgCtx = NSGraphicsContext.current?.cgContext else { return false }
            
            cgCtx.saveGState()
            cgCtx.setAlpha(CGFloat(self.opacity))
            
            if self.shadow {
                let shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
                cgCtx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.0, color: shadowColor)
            }
            
            if self.glow {
                let glowColor = tint.withAlphaComponent(0.6).cgColor
                cgCtx.setShadow(offset: .zero, blur: 8.0, color: glowColor)
            }
            
            cgCtx.translateBy(x: side/2, y: side/2)
            cgCtx.rotate(by: CGFloat(self.rotation) * .pi / 180.0)
            cgCtx.translateBy(x: -side/2, y: -side/2)
            
            switch self.style {
            case .whiteCircle, .dot:
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                tint.setFill()
                path.fill()
                if self.outline {
                    NSColor.black.withAlphaComponent(0.25).setStroke()
                    path.lineWidth = 1.0
                    path.stroke()
                }
            case .crosshair:
                let path = NSBezierPath()
                let mid = side / 2
                path.move(to: NSPoint(x: mid, y: 2))
                path.line(to: NSPoint(x: mid, y: side - 2))
                path.move(to: NSPoint(x: 2, y: mid))
                path.line(to: NSPoint(x: side - 2, y: mid))
                tint.setStroke()
                path.lineWidth = max(1.0, side * 0.08)
                path.stroke()
                if self.outline {
                    let outPath = NSBezierPath()
                    outPath.move(to: NSPoint(x: mid, y: 1))
                    outPath.line(to: NSPoint(x: mid, y: side - 1))
                    outPath.move(to: NSPoint(x: 1, y: mid))
                    outPath.line(to: NSPoint(x: side - 1, y: mid))
                    NSColor.black.withAlphaComponent(0.3).setStroke()
                    outPath.lineWidth = path.lineWidth + 1
                    outPath.stroke()
                }
            case .custom:
                if let img = self.cachedCustomImage {
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                } else {
                    let path = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                    tint.setFill()
                    path.fill()
                }
            default:
                break
            }
            
            cgCtx.restoreGState()
            return true
        }
        
        var hotPoint: NSPoint
        switch hotspotType {
        case .center:
            hotPoint = NSPoint(x: side/2, y: side/2)
        case .topLeft:
            hotPoint = NSPoint(x: 0, y: 0)
        case .bottomLeft:
            hotPoint = NSPoint(x: 0, y: side)
        case .custom:
            hotPoint = NSPoint(x: side * CGFloat(hotspotX), y: side * CGFloat(hotspotY))
        }
        
        activeCursor = NSCursor(image: image, hotSpot: hotPoint)
    }
}
