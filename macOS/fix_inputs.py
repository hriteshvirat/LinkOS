import sys

path = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneSession.swift"
with open(path, "r") as f:
    text = f.read()

# Add activeAppCategory
text = text.replace('    @Published var connectionState: PhoneConnectionState = .disconnected', '    @Published var connectionState: PhoneConnectionState = .disconnected\n    @Published var activeAppCategory: String = "unknown"')

new_methods = """
    func sendDown(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "DOWN", "x": x, "y": y]) }
    }
    
    func sendMove(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "MOVE", "x": x, "y": y]) }
    }
    
    func sendUp(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "UP", "x": x, "y": y]) }
    }
    
    func sendDoubleClick(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "DOUBLE_CLICK", "x": x, "y": y]) }
    }
    
    func sendLongPress(x: Float, y: Float) {
        Task { await sendControlMessage(["action": "LONG_PRESS", "x": x, "y": y]) }
    }
    
    func sendDrag(startX: Float, startY: Float, endX: Float, endY: Float, duration: Int = 300) {
        Task { await sendControlMessage(["action": "DRAG", "startX": startX, "startY": startY, "endX": endX, "endY": endY, "duration": duration]) }
    }
    
    func sendScroll(x: Float, y: Float, deltaX: CGFloat, deltaY: CGFloat) {
        Task { await sendControlMessage(["action": "SCROLL", "x": x, "y": y, "deltaX": Float(deltaX), "deltaY": Float(deltaY)]) }
    }
    
    func sendGestureStream(gestureType: String, phase: String, x: Float, y: Float, scale: Float, rotation: Float, pressure: Float) {
        Task { await sendControlMessage([
            "action": "GESTURE_STREAM", 
            "gestureType": gestureType, 
            "phase": phase, 
            "x": x, 
            "y": y, 
            "scale": scale, 
            "rotation": rotation, 
            "pressure": pressure
        ]) }
    }
"""

text = text.replace('    // MARK: - Inbound Input Injection Actions', '    // MARK: - Inbound Input Injection Actions\n' + new_methods)

with open(path, "w") as f:
    f.write(text)
