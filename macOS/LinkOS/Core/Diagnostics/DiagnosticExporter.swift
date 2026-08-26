import Foundation
import AppKit

final class DiagnosticExporter {
    static let shared = DiagnosticExporter()
    
    private init() {}
    
    @MainActor
    func generateDiagnosticBundle() -> URL? {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let bundleName = "LinkOS_Diagnostics_\(timestamp)"
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(bundleName)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            
            let activeSession = PhoneSessionManager.shared.activeSession
            var sessionDump = "LinkOS Phone Mirroring Diagnostics\n"
            sessionDump += "==================================\n\n"
            sessionDump += "Session ID: \(activeSession.sessionId)\n"
            sessionDump += "State: \(activeSession.mirrorState.rawValue)\n"
            sessionDump += "FPS: \(activeSession.fps)\n"
            sessionDump += "Latency: \(activeSession.latencyMs)ms\n"
            sessionDump += "Bitrate: \(activeSession.currentBitrateKbps) kbps\n\n"
            sessionDump += "Decoder Watchdog Dump:\n"
            sessionDump += activeSession.h264Decoder.getWatchdogDump() + "\n\n"
            sessionDump += "Audio Metrics:\n"
            sessionDump += PhoneAudioService.shared.getMetricsReport() + "\n\n"
            
            let dumpURL = tempDir.appendingPathComponent("session_dump.txt")
            try sessionDump.write(to: dumpURL, atomically: true, encoding: .utf8)
            
            // Collect Logs (from LinkOSLogger in-memory buffer if possible, or just note it)
            let logsURL = tempDir.appendingPathComponent("logs.txt")
            let logWarning = "Log export requires direct access to OSLog or an in-memory ring buffer (not yet implemented). Look for [SESSION: \(activeSession.sessionId)] in Console.app."
            try logWarning.write(to: logsURL, atomically: true, encoding: .utf8)
            
            // Create ZIP (using NSFileCoordinator or a simple Process)
            let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleName).zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-r", zipURL.path, tempDir.lastPathComponent]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            try process.run()
            process.waitUntilExit()
            
            LinkOSLogger.shared.info("[DiagnosticExporter] Bundle generated at \(zipURL.path)", category: .media)
            return zipURL
        } catch {
            LinkOSLogger.shared.error("[DiagnosticExporter] Failed to generate bundle: \(error.localizedDescription)", category: .media)
            return nil
        }
    }
    
    @MainActor
    func promptUserToSaveBundle() {
        guard let bundleURL = generateDiagnosticBundle() else { return }
        
        let savePanel = NSSavePanel()
        savePanel.title = "Save Diagnostics Bundle"
        savePanel.nameFieldStringValue = bundleURL.lastPathComponent
        savePanel.allowedContentTypes = [.zip]
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.moveItem(at: bundleURL, to: url)
                    LinkOSLogger.shared.info("[DiagnosticExporter] Bundle saved to \(url.path)", category: .media)
                } catch {
                    LinkOSLogger.shared.error("[DiagnosticExporter] Failed to save bundle: \(error.localizedDescription)", category: .media)
                }
            }
        }
    }
}
