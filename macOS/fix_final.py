import re

# 1. PhoneSession.swift fixes
path_session = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneSession.swift"
with open(path_session, "r") as f:
    text_session = f.read()

enum_def = """
enum PhoneMirrorState: String {
    case disconnected
    case connecting
    case receivingStream
    case decoderReady
    case presenting
    case streaming
    case paused
    case stopping
    case stopped
}

@MainActor
final class PhoneSession: ObservableObject {
    @Published var mirrorState: PhoneMirrorState = .disconnected
"""

text_session = text_session.replace("@MainActor\nfinal class PhoneSession: ObservableObject {", enum_def)

missing_methods = """
    func sendRotateDevice(direction: String) {
        Task { await sendControlMessage(["action": direction]) }
    }
    
    func startScreenRecording() {
        Task { await sendControlMessage(["action": "START_RECORDING"]) }
    }
    
    func stopScreenRecording() {
        Task { await sendControlMessage(["action": "STOP_RECORDING"]) }
    }
"""

text_session = text_session.replace("    // MARK: - Inbound Input Injection Actions", "    // MARK: - Inbound Input Injection Actions\n" + missing_methods)

with open(path_session, "w") as f:
    f.write(text_session)


# 2. PhoneWindowController.swift fixes
path_controller = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneWindowController.swift"
with open(path_controller, "r") as f:
    text_controller = f.read()

text_controller = text_controller.replace(
    ".sink { [weak window] state, battery, latency, fps in",
    ".sink { [weak window] (state: String, battery: Int, latency: Double, fps: Double) in"
)
text_controller = text_controller.replace(
    "toolbarPanel!.frameForEdge(toolbarPanel!.dockedEdge, phoneFrame: newFrame)",
    "toolbarPanel!.frameForEdge(MirroringWorkspace.shared.activeToolbarEdge, phoneFrame: newFrame)"
)

with open(path_controller, "w") as f:
    f.write(text_controller)


# 3. PhoneToolbarPanel.swift fixes
path_panel = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/UI/PhoneMirroring/PhoneToolbarPanel.swift"
with open(path_panel, "r") as f:
    text_panel = f.read()

text_panel = text_panel.replace(
    "let expanded = showControlsPopover",
    "let expanded = MirroringWorkspace.shared.showControlsPopover"
)
text_panel = text_panel.replace(
    "let newFrame = frameForEdge(dockedEdge, phoneFrame: phone.frame)",
    "let newFrame = frameForEdge(MirroringWorkspace.shared.activeToolbarEdge, phoneFrame: phone.frame)"
)

with open(path_panel, "w") as f:
    f.write(text_panel)
