import re

path_session = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/Features/PhoneMirroring/PhoneSession.swift"
with open(path_session, "r") as f:
    text_session = f.read()

props = """
    @Published var sessionId: String = UUID().uuidString
    var onSampleBufferReady: ((CMSampleBuffer) -> Void)?
    var isSessionAlive: Bool = true
"""

text_session = text_session.replace("@Published var currentFrame: CGImage? = nil", props + "\n    @Published var currentFrame: CGImage? = nil")

# Remove the memory management lines from stopSession since we don't have VTDecompressionSession anymore
text_session = text_session.replace("self.lastSPS = nil\n        self.lastPPS = nil\n        self.formatDescription = nil", "")
text_session = text_session.replace("if decompressionSession != nil {\n            VTDecompressionSessionInvalidate(decompressionSession!)\n            decompressionSession = nil\n        }", "")
text_session = text_session.replace("decoderQueue.async { [weak self] in\n            self?.pendingFrames.removeAll()\n            self?.queueLength = 0\n        }", "")

with open(path_session, "w") as f:
    f.write(text_session)
