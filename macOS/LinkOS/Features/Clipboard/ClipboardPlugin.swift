import Foundation
import AppKit
import UserNotifications

/// Unified rich clipboard synchronizer supporting Text, Rich Text, Images, and File references.
/// Integrates exponential backoff retries, loop prevention, and offline replay buffers.
@MainActor
final class ClipboardPlugin: LinkOSPlugin {
    let pluginId = "clipboard"
    let displayName = "Universal Clipboard"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["clipboard"]
    let requiredPermissions: Set<String> = ["CLIPBOARD_READ", "CLIPBOARD_WRITE"]
    
    private(set) var isActive = false
    private var _monitor: ClipboardMonitor?
    private let store = ClipboardHistoryManager.shared
    private weak var connectionManager: ConnectionManager?
    
    private var monitor: ClipboardMonitor {
        if let m = _monitor { return m }
        let m = ClipboardMonitor()
        _monitor = m
        return m
    }
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    // MARK: - Ownership Tracking
    
    private var lastSyncedText: String?
    private var lastSyncTimestamp: TimeInterval = 0
    private var lastSyncOrigin: String = "local"
    private var activationTimestamp: TimeInterval = 0
    
    // MARK: - Offline Buffer
    
    private var offlineBuffer: [(ClipboardHistoryItem, Data)] = []
    private let maxOfflineBufferSize = 20
    
    // MARK: - Retry & Backoff
    
    private var retryCount = 0
    private let maxRetries = 3
    private var retryTask: Task<Void, Never>?
    
    func activate() async throws {
        isActive = true
        self.activationTimestamp = Date().timeIntervalSince1970
        monitor.startMonitoring()
        monitor.onClipboardChanged = { [weak self] item, payload in
            Task {
                guard let self = self else { return }
                
                // Prevent loops
                if let text = item.fullText, text == self.lastSyncedText && self.lastSyncOrigin == "remote" {
                    return
                }
                
                let now = Date().timeIntervalSince1970
                if now - self.lastSyncTimestamp < 0.5 && self.lastSyncOrigin == "remote" {
                    LinkOSLogger.shared.info("[Clipboard] Conflict detected – local took precedence", category: .clipboard)
                }
                
                self.lastSyncedText = item.fullText
                self.lastSyncTimestamp = now
                self.lastSyncOrigin = "local"
                
                self.store.addItem(item)
                if let text = item.fullText, let textData = text.data(using: .utf8) {
                    await self.sendWithRetry(item: item, data: textData)
                }
            }
        }
        
        await replayOfflineBuffer()
        LinkOSLogger.shared.info("[Clipboard] Universal Clipboard activated", category: .clipboard)
    }
    
    func deactivate() async {
        isActive = false
        retryTask?.cancel()
        monitor.stopMonitoring()
        LinkOSLogger.shared.info("[Clipboard] Universal Clipboard deactivated", category: .clipboard)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        guard let text = String(data: message.payload, encoding: .utf8), !text.isEmpty else { return }
        
        // Loop prevention
        if text == lastSyncedText && lastSyncOrigin == "local" { return }
        
        let now = Date().timeIntervalSince1970
        if now - lastSyncTimestamp < 0.5 && lastSyncOrigin == "local" {
            LinkOSLogger.shared.info("[Clipboard] Conflict detected – local wins over remote", category: .clipboard)
            return
        }
        
        self.lastSyncedText = text
        self.lastSyncTimestamp = now
        self.lastSyncOrigin = "remote"
        
        // Write natively to macOS General Pasteboard
        monitor.copyToPasteboard(text: text)
        
        // Create history item for local UI store
        let historyItem = ClipboardHistoryItem(
            id: UUID().uuidString,
            contentType: text.hasPrefix("http://") || text.hasPrefix("https://") ? .url : .text,
            previewText: String(text.prefix(200)),
            fullText: text,
            mimeType: "text/plain",
            sourceApp: "Android Device",
            timestamp: Date(),
            isPinned: false,
            isFavourite: false,
            sizeBytes: text.utf8.count
        )
        self.store.addItem(historyItem)
        LinkOSLogger.shared.info("[Clipboard] Synced clipboard text from Android", category: .clipboard)
        
        // Show native macOS notification confirming clipboard sync only after initial connection phase (> 3.5s)
        if now - self.activationTimestamp > 3.5 {
            let notifContent = UNMutableNotificationContent()
            notifContent.title = "Clipboard Synced"
            let preview = text.count > 40 ? "\(text.prefix(40))…" : text
            notifContent.body = "✓ Synced from Android: \"\(preview)\""
            notifContent.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: notifContent, trigger: trigger)
            try? await UNUserNotificationCenter.current().add(request)
        } else {
            LinkOSLogger.shared.info("[Clipboard] Suppressed initial connection clipboard toast", category: .clipboard)
        }
        
        if let correlationId = message.correlationId, let manager = connectionManager {
            let responsePayload = "{\"status\":\"success\"}".data(using: .utf8)!
            let responseMsg = MessageRouter.createResponse(channel: "clipboard", payload: responsePayload, correlationId: correlationId)
            try? await manager.send(responseMsg, to: message.deviceId)
            LinkOSLogger.shared.info("[Clipboard] Dispatched ACK response back to Android for msg: \(correlationId)", category: .clipboard)
        }
    }
    
    func commandPaletteActions() -> [CommandPaletteAction] {
        [
            CommandPaletteAction(
                id: "clipboard.search",
                title: "Search Clipboard History",
                subtitle: "Browse copied items and text snippets",
                icon: "doc.on.clipboard",
                keywords: ["clipboard", "copy", "paste", "history"],
                category: "Clipboard",
                action: {
                    LinkOSLogger.shared.info("Triggered Clipboard Search from Command Palette", category: .clipboard)
                }
            ),
            CommandPaletteAction(
                id: "clipboard.clear",
                title: "Clear Clipboard History",
                subtitle: "Remove unpinned clipboard items",
                icon: "trash",
                keywords: ["clipboard", "clear", "delete"],
                category: "Clipboard",
                action: {
                    Task { @MainActor in
                        ClipboardHistoryManager.shared.clearHistory()
                    }
                }
            )
        ]
    }
    
    private func sendWithRetry(item: ClipboardHistoryItem, data: Data) async {
        retryCount = 0
        while retryCount <= maxRetries {
            do {
                try await broadcastClipboardUpdate(item: item, data: data)
                retryCount = 0
                return
            } catch {
                retryCount += 1
                if retryCount > maxRetries {
                    bufferOffline(item: item, data: data)
                    return
                }
                let delay = pow(2.0, Double(retryCount - 1))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
    
    private func bufferOffline(item: ClipboardHistoryItem, data: Data) {
        if offlineBuffer.count >= maxOfflineBufferSize {
            offlineBuffer.removeFirst()
        }
        offlineBuffer.append((item, data))
    }
    
    private func replayOfflineBuffer() async {
        guard !offlineBuffer.isEmpty else { return }
        let buffered = offlineBuffer
        offlineBuffer.removeAll()
        for (item, data) in buffered {
            try? await broadcastClipboardUpdate(item: item, data: data)
        }
    }
    
    private func broadcastClipboardUpdate(item: ClipboardHistoryItem, data: Data) async throws {
        guard let connectionManager else { throw ClipboardSyncError.noConnection }
        let payload = MessageRouter.createEvent(channel: "clipboard", payload: data)
        await connectionManager.broadcast(payload)
    }
}

enum ClipboardSyncError: Error {
    case noConnection
}
