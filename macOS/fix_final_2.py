import re

# 1. PhoneSession.swift fixes
path_session = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneSession.swift"
with open(path_session, "r") as f:
    text_session = f.read()

# Add missing properties
props = """
    @Published var expectedSessionGeneration: UInt8 = 0
    @Published var isPaused: Bool = false
    @Published var activeAppPackage: String = ""
"""
text_session = text_session.replace("@Published var activeAppCategory: String = \"unknown\"", "@Published var activeAppCategory: String = \"unknown\"\n" + props)

# Fix init access
text_session = text_session.replace("private init() {", "init() {")

# Add missing send methods or replace them
# We can just leave sendControlMessage as internal (it is).

with open(path_session, "w") as f:
    f.write(text_session)


# 2. PhoneInputService.swift fixes
path_input = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneInputService.swift"
with open(path_input, "r") as f:
    text_input = f.read()

# Instead of relying on sendGestureStream, let's just make PhoneInputService call sendControlMessage directly.
# Replace `PhoneSession.shared.sendGestureStream(` with `Task { await PhoneSession.shared.sendControlMessage([`
text_input = re.sub(r'PhoneSession\.shared\.sendGestureStream\(([\s\S]*?)\n        \)', 
                    r'Task { await PhoneSession.shared.sendControlMessage(["action": "GESTURE_STREAM", \1\n        ]) }', 
                    text_input)

# Wait, `Task { await PhoneSession.shared.sendControlMessage([` means we are passing keyword args to dictionary. In Swift dictionaries use `:` instead of `:`?
# Actually kwargs look exactly like dictionary entries: `gestureType: "SWIPE",`
# So `[ gestureType: "SWIPE", phase: "CHANGED", ... ]` is valid Swift dictionary syntax if keys are strings! But wait, `normX:` needs quotes `"normX":`.
# It's safer to just do a manual string replace on PhoneInputService.

# Let's replace the whole handleMagnify, handleRotate, handleSwipe, handlePressureChange, handleScroll to use sendControlMessage.

replacement_scroll = """
        let payload: [String: Any] = [
            "action": "GESTURE_STREAM",
            "gestureType": "SCROLL",
            "phase": phase,
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "deltaX": Float(deltaX),
            "deltaY": Float(deltaY),
            "velocity": Float(velocity),
            "momentum": isMomentum,
            "timestamp": event.timestamp
        ]
        Task { await PhoneSession.shared.sendControlMessage(payload) }
"""
text_input = re.sub(r'PhoneSession\.shared\.sendGestureStream\(\n\s*gestureType: "SCROLL"[\s\S]*?timestamp: event\.timestamp\n\s*\)', replacement_scroll, text_input)


replacement_pinch = """
        let payload: [String: Any] = [
            "action": "GESTURE_STREAM",
            "gestureType": "PINCH",
            "phase": phase,
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "scale": Float(scale),
            "timestamp": event.timestamp
        ]
        Task { await PhoneSession.shared.sendControlMessage(payload) }
"""
text_input = re.sub(r'PhoneSession\.shared\.sendGestureStream\(\n\s*gestureType: "PINCH"[\s\S]*?timestamp: event\.timestamp\n\s*\)', replacement_pinch, text_input)

replacement_rotate = """
        let payload: [String: Any] = [
            "action": "GESTURE_STREAM",
            "gestureType": "ROTATE",
            "phase": phase,
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "rotation": Float(event.rotation),
            "timestamp": event.timestamp
        ]
        Task { await PhoneSession.shared.sendControlMessage(payload) }
"""
text_input = re.sub(r'PhoneSession\.shared\.sendGestureStream\(\n\s*gestureType: "ROTATE"[\s\S]*?timestamp: event\.timestamp\n\s*\)', replacement_rotate, text_input)

replacement_swipe = """
        let payload: [String: Any] = [
            "action": "GESTURE_STREAM",
            "gestureType": "SWIPE",
            "phase": "CHANGED",
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "deltaX": Float(event.deltaX),
            "deltaY": Float(event.deltaY),
            "timestamp": event.timestamp
        ]
        Task { await PhoneSession.shared.sendControlMessage(payload) }
"""
text_input = re.sub(r'PhoneSession\.shared\.sendGestureStream\(\n\s*gestureType: "SWIPE"[\s\S]*?timestamp: event\.timestamp\n\s*\)', replacement_swipe, text_input)

replacement_pressure = """
        let payload: [String: Any] = [
            "action": "GESTURE_STREAM",
            "gestureType": "PRESSURE",
            "phase": "CHANGED",
            "normX": Float(norm.x),
            "normY": Float(norm.y),
            "pressure": Float(event.pressure),
            "stage": event.stage,
            "timestamp": event.timestamp
        ]
        Task { await PhoneSession.shared.sendControlMessage(payload) }
"""
text_input = re.sub(r'PhoneSession\.shared\.sendGestureStream\(\n\s*gestureType: "PRESSURE"[\s\S]*?timestamp: event\.timestamp\n\s*\)', replacement_pressure, text_input)

with open(path_input, "w") as f:
    f.write(text_input)


# 3. PhoneMirroringPlugin.swift fixes
path_plugin = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneMirroringPlugin.swift"
with open(path_plugin, "r") as f:
    text_plugin = f.read()

text_plugin = text_plugin.replace(
    "PhoneSession.shared.updateDiagnostic(stage: stage, ok: ok, error: error, sessionId: sessionId)",
    "PhoneSession.shared.updateDiagnostic(stage: stage, ok: ok, error: error)"
)

with open(path_plugin, "w") as f:
    f.write(text_plugin)

