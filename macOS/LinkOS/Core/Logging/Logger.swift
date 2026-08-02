import Foundation
import os

/// Structured logging system for LinkOS.
/// Wraps Apple's unified logging with structured categories and export capability.
/// Enhanced with level filtering, performance counters, and production-ready cleanup.
final class LinkOSLogger {
    static let shared = LinkOSLogger()
    
    private let subsystem = "com.linkos.macos"
    private var logBuffer: [LogEntry] = []
    private let bufferQueue = DispatchQueue(label: "com.linkos.logger", qos: .utility)
    private let maxBufferSize = 10_000
    
    /// Controls the minimum log level that gets recorded.
    var minimumLevel: LogLevel = .debug
    
    /// When true, only high-level feature events are stored (Features Only mode).
    var featuresOnlyMode: Bool = false
    
    /// Categories considered "feature-level" for Features Only filtering.
    private let featureCategories: Set<String> = [
        LogCategory.clipboard.rawValue,
        LogCategory.input.rawValue,
        LogCategory.media.rawValue,
        LogCategory.files.rawValue,
        LogCategory.notifications.rawValue,
        LogCategory.presence.rawValue,
    ]
    
    private init() {}
    
    // MARK: - Public API
    
    func debug(_ message: String, category: LogCategory, metadata: [String: String]? = nil) {
        log(level: .debug, message: message, category: category, metadata: metadata)
    }
    
    func info(_ message: String, category: LogCategory, metadata: [String: String]? = nil) {
        log(level: .info, message: message, category: category, metadata: metadata)
    }
    
    func warning(_ message: String, category: LogCategory, metadata: [String: String]? = nil) {
        log(level: .warning, message: message, category: category, metadata: metadata)
    }
    
    func error(_ message: String, category: LogCategory, error: Error? = nil, metadata: [String: String]? = nil) {
        var meta = metadata ?? [:]
        if let error = error {
            meta["error"] = String(describing: error)
        }
        log(level: .error, message: message, category: category, metadata: meta)
    }
    
    func critical(_ message: String, category: LogCategory, error: Error? = nil, metadata: [String: String]? = nil) {
        var meta = metadata ?? [:]
        if let error = error {
            meta["error"] = String(describing: error)
        }
        log(level: .critical, message: message, category: category, metadata: meta)
    }
    
    /// Export logs as JSON for bug reports. Sanitizes sensitive data.
    func exportLogs() -> Data? {
        bufferQueue.sync {
            let sanitized = logBuffer.map { $0.sanitized() }
            return try? JSONEncoder().encode(sanitized)
        }
    }
    
    // MARK: - Private
    
    private func log(level: LogLevel, message: String, category: LogCategory, metadata: [String: String]?) {
        // Level filtering
        guard level.numericValue >= minimumLevel.numericValue else { return }
        
        // Features Only mode filtering
        if featuresOnlyMode && !featureCategories.contains(category.rawValue) && level.numericValue < LogLevel.warning.numericValue {
            return
        }
        
        let osLog = OSLog(subsystem: subsystem, category: category.rawValue)
        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            category: category,
            message: message,
            metadata: metadata
        )
        
        // Apple unified logging
        switch level {
        case .debug:    os_log(.debug, log: osLog, "%{public}@", message)
        case .info:     os_log(.info, log: osLog, "%{public}@", message)
        case .warning:  os_log(.default, log: osLog, "⚠️ %{public}@", message)
        case .error:    os_log(.error, log: osLog, "%{public}@", message)
        case .critical: os_log(.fault, log: osLog, "%{public}@", message)
        }
        
        // Also print to stderr for real-time command-line diagnostics
        fputs("[\(level.rawValue.uppercased())] [\(category.rawValue)] \(message)\n", stderr)
        
        // Buffer for export
        bufferQueue.async { [weak self] in
            guard let self else { return }
            self.logBuffer.append(entry)
            if self.logBuffer.count > self.maxBufferSize {
                self.logBuffer.removeFirst(self.logBuffer.count - self.maxBufferSize)
            }
        }
    }
    
    func getBuffer() -> [LogEntry] {
        bufferQueue.sync {
            self.logBuffer
        }
    }
    
    /// Get filtered buffer by category.
    func getBuffer(category: LogCategory) -> [LogEntry] {
        bufferQueue.sync {
            self.logBuffer.filter { $0.category == category.rawValue }
        }
    }
    
    /// Get filtered buffer by level.
    func getBuffer(minLevel: LogLevel) -> [LogEntry] {
        bufferQueue.sync {
            self.logBuffer.filter { LogLevel(rawValue: $0.level.rawValue)?.numericValue ?? 0 >= minLevel.numericValue }
        }
    }
    
    func clearBuffer() {
        bufferQueue.async {
            self.logBuffer.removeAll()
        }
    }
    
    /// Generate a clean connection diagnostics report (no legacy stages).
    func generateDiagnosticsReport(connectionState: String) -> String {
        var sb = ""
        sb += "========================\n"
        sb += "LINKOS DIAGNOSTICS REPORT\n"
        sb += "========================\n\n"
        sb += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        sb += "Device: \(Host.current().localizedName ?? "Mac")\n"
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sb += "Time: \(formatter.string(from: Date()))\n"
        sb += "Connection State: \(connectionState)\n\n"
        
        sb += "------------------------\n"
        sb += "RECENT LOG ENTRIES\n"
        sb += "------------------------\n"
        
        let logs = getBuffer()
        let logTimeFormatter = DateFormatter()
        logTimeFormatter.dateFormat = "HH:mm:ss.SSS"
        
        for log in logs.suffix(200) {
            sb += "\(logTimeFormatter.string(from: log.timestamp)) [\(log.category)] [\(log.level.rawValue.uppercased())] \(log.message)\n"
        }
        sb += "========================\n"
        sb += "END\n"
        sb += "========================\n"
        return sb
    }
}

// MARK: - Types

enum LogLevel: String, Codable, CaseIterable {
    case debug, info, warning, error, critical
    
    var numericValue: Int {
        switch self {
        case .debug:    return 0
        case .info:     return 1
        case .warning:  return 2
        case .error:    return 3
        case .critical: return 4
        }
    }
}

enum LogCategory: String, CaseIterable {
    case app = "App"
    case network = "Network"
    case security = "Security"
    case protocol_ = "Protocol"
    case plugin = "Plugin"
    case clipboard = "Clipboard"
    case input = "Input"
    case media = "Media"
    case files = "Files"
    case notifications = "Notifications"
    case terminal = "Terminal"
    case ai = "AI"
    case presence = "Presence"
    case performance = "Performance"
}

struct LogEntry: Codable {
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    let metadata: [String: String]?
    
    init(timestamp: Date, level: LogLevel, category: LogCategory, message: String, metadata: [String: String]?) {
        self.timestamp = timestamp
        self.level = level
        self.category = category.rawValue
        self.message = message
        self.metadata = metadata
    }
    
    /// Remove sensitive data (API keys, tokens, encryption keys) from metadata.
    func sanitized() -> LogEntry {
        let sensitiveKeys = Set(["api_key", "token", "password", "secret", "key", "private_key", "session_ticket"])
        guard let metadata = metadata else { return self }
        let cleaned = metadata.mapValues { value in
            sensitiveKeys.contains(where: { metadata.keys.contains($0) }) ? "[REDACTED]" : value
        }
        return LogEntry(timestamp: timestamp, level: level,
                        category: LogCategory(rawValue: category) ?? .app,
                        message: message, metadata: cleaned)
    }
}
