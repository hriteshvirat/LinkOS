import Cocoa
import Carbon

@MainActor
final class PhoneInputService {
    static let shared = PhoneInputService()
    
    private var isDragging = false
    private var dragStart = CGPoint.zero
    private var lastDragTime: Date = Date()
    
    private init() {}
    
    func handleMouseDown(at location: CGPoint, viewSize: CGSize) {
        let norm = normalize(location, size: viewSize)
        PhoneSession.shared.sendClick(x: Float(norm.x), y: Float(norm.y))
        
        isDragging = true
        dragStart = norm
        lastDragTime = Date()
    }
    
    func handleMouseDragged(to location: CGPoint, viewSize: CGSize) {
        guard isDragging else { return }
        
        let norm = normalize(location, size: viewSize)
        let now = Date()
        let intervalMs = Int(now.timeIntervalSince(lastDragTime) * 1000.0)
        
        // Batch and interpolate drag events to prevent congestion while maintaining precision
        if intervalMs >= 50 {
            PhoneSession.shared.sendSwipe(
                startX: Float(dragStart.x),
                startY: Float(dragStart.y),
                endX: Float(norm.x),
                endY: Float(norm.y),
                duration: intervalMs
            )
            dragStart = norm
            lastDragTime = now
        }
    }
    
    func handleMouseUp(at location: CGPoint, viewSize: CGSize) {
        guard isDragging else { return }
        let norm = normalize(location, size: viewSize)
        let now = Date()
        let intervalMs = max(50, Int(now.timeIntervalSince(lastDragTime) * 1000.0))
        
        PhoneSession.shared.sendSwipe(
            startX: Float(dragStart.x),
            startY: Float(dragStart.y),
            endX: Float(norm.x),
            endY: Float(norm.y),
            duration: intervalMs
        )
        isDragging = false
    }
    
    func handleScroll(with event: NSEvent, viewSize: CGSize) {
        let location = event.locationInWindow
        let norm = normalize(location, size: viewSize)
        
        // Emulate scroll inertia using swipe gestures in opposite direction for natural scroll
        let deltaY = Float(event.scrollingDeltaY)
        let scale: Float = 0.05
        let endY = Float(norm.y) + (deltaY * scale)
        
        PhoneSession.shared.sendSwipe(
            startX: Float(norm.x),
            startY: Float(norm.y),
            endX: Float(norm.x),
            endY: endY.coerceIn(0.0, 1.0),
            duration: 150
        )
    }
    
    func handleKeyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers ?? ""
        
        // Translate standard backspace and navigation keypresses
        if event.keyCode == 51 { // Backspace
            PhoneSession.shared.sendBackspace()
        } else if event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 { // Arrow keys
            // Map arrow keys or navigation events if needed, fallback to text insertion
        } else if !characters.isEmpty {
            PhoneSession.shared.sendText(characters)
        }
    }
    
    // MARK: - Private Helpers
    
    private func normalize(_ location: CGPoint, size: CGSize) -> CGPoint {
        guard size.width > 0 && size.height > 0 else { return .zero }
        
        // Invert y axis for coordinate mapping consistency between Android and macOS
        let x = location.x / size.width
        let y = 1.0 - (location.y / size.height)
        
        return CGPoint(x: x.coerceIn(0.0, 1.0), y: y.coerceIn(0.0, 1.0))
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
