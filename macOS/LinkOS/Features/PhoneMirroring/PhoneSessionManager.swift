import Foundation
import Combine

@MainActor
final class PhoneSessionManager: ObservableObject {
    static let shared = PhoneSessionManager()
    
    @Published var activeSession = PhoneSession()
    private var isTransitioning = false
    
    /// Set to true when the user manually disconnects mirroring.
    /// While true, all automatic reconnect and resume paths are suppressed.
    /// MUST only be reset to false by an explicit user gesture (e.g. pressing the Mirror button).
    /// Do NOT reset inside any automatic path such as recreateAndStartSession or connectionDidChange.
    var userStoppedMirroring: Bool = false
    
    private init() {}
    
    /// Synchronous teardown barrier before creating a pristine session.
    /// WARNING: This does NOT reset userStoppedMirroring. Only the explicit user gesture path resets it.
    func recreateAndStartSession() async {
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneSessionManager] recreateAndStartSession called. Stack Trace:\n\(trace)", category: .media)

        guard !isTransitioning else {
            LinkOSLogger.shared.warning("[PhoneSessionManager] Recreate requested while already transitioning. Ignoring.", category: .media)
            return
        }
        isTransitioning = true
        defer { isTransitioning = false }
        
        LinkOSLogger.shared.info("[PhoneSessionManager] Initiating structured synchronous session recreation", category: .media)
        
        // 1. Synchronous Teardown Barrier
        await activeSession.tearDown(sendRemoteStop: true)
        
        // 2. Create pristine session with brand new UUID and clean pipeline
        let newSession = PhoneSession()
        let sessionObjId = ObjectIdentifier(newSession)
        LinkOSLogger.shared.info("[PhoneSessionManager] Created pristine PhoneSession [\(sessionObjId)] (ID: \(newSession.sessionId))", category: .media)
        if ConnectionStateManager.shared.phase == .connected {
            newSession.connectionState = .connected
        }
        
        // 3. Eagerly wire onPixelBufferReady BEFORE publishing activeSession and starting the decoder.
        //    This closes the race where the decoder fires frames on the background thread before
        //    SwiftUI's updateNSView has a chance to call wireSession() on the main thread.
        PhoneWindowController.shared.wireSessionEagerly(newSession)
        
        // 4. Publish new session (SwiftUI will call updateNSView, which will see the already-wired callback)
        activeSession = newSession
        
        // 5. Start the newly assigned session
        await newSession.startSession()
    }
    
    func stopSession(isManual: Bool = true) async {
        if isManual {
            userStoppedMirroring = true
            LinkOSLogger.shared.info("[PhoneSessionManager] Manual disconnect: userStoppedMirroring = true. Auto-reconnect suppressed.", category: .media)
        }
        await activeSession.stopSession(isManual: isManual)
    }
    
    func pauseSession() async {
        await activeSession.pauseSession()
    }
    
    func resumeSession() async {
        let trace = Thread.callStackSymbols.prefix(15).joined(separator: "\n")
        LinkOSLogger.shared.info("[PhoneSessionManager] resumeSession called. Stack Trace:\n\(trace)", category: .media)
        await activeSession.resumeSession()
    }
}
