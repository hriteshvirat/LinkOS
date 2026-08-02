import AppKit
import Combine

/// Types of clipboard content supported by LinkOS.
enum ClipboardContentType: String, Codable {
    case text
    case richText
    case image
    case fileReference
    case url
    case codeSnippet
}

/// A item in the clipboard history.
struct ClipboardHistoryItem: Identifiable, Codable, Equatable {
    let id: String
    let contentType: ClipboardContentType
    let previewText: String
    let fullText: String?
    let mimeType: String
    let sourceApp: String?
    let timestamp: Date
    var isPinned: Bool
    var isFavourite: Bool
    let sizeBytes: Int
}

/// Monitors NSPasteboard for changes and notifies subscribers.
@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published var lastItem: ClipboardHistoryItem?
    
    private let pasteboard = NSPasteboard.general
    private var changeCount: Int
    private var timer: AnyCancellable?
    
    var onClipboardChanged: ((ClipboardHistoryItem, Data) -> Void)?
    
    init() {
        self.changeCount = pasteboard.changeCount
    }
    
    func startMonitoring() {
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkPasteboard()
            }
    }
    
    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }
    
    func copyToPasteboard(text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        self.changeCount = pasteboard.changeCount
    }
    
    func copyToPasteboard(data: Data, forType type: NSPasteboard.PasteboardType) {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        self.changeCount = pasteboard.changeCount
    }
    
    func copyToPasteboard(image: NSImage) {
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        self.changeCount = pasteboard.changeCount
    }
    
    private func checkPasteboard() {
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName
        
        // 1. Files
        if let filenames = pasteboard.propertyList(forType: .init(rawValue: "NSFilenamesPboardType")) as? [String] {
            let isTempRemoteCopy = filenames.allSatisfy { path in
                path.hasPrefix(NSTemporaryDirectory())
            }
            if isTempRemoteCopy {
                LinkOSLogger.shared.info("[Clipboard] Skipping clipboard sync for remote file copy: \(filenames)", category: .clipboard)
                return
            }
            
            let filesStr = filenames.joined(separator: "\n")
            let item = ClipboardHistoryItem(
                id: UUID().uuidString,
                contentType: .fileReference,
                previewText: "Files (\(filenames.count) items)",
                fullText: filesStr,
                mimeType: "text/uri-list",
                sourceApp: activeApp,
                timestamp: Date(),
                isPinned: false,
                isFavourite: false,
                sizeBytes: filesStr.utf8.count
            )
            self.lastItem = item
            if let payload = try? JSONEncoder().encode(item) {
                onClipboardChanged?(item, payload)
            }
            return
        }
        // 2. Text & URLs (Highest Priority Text with RTF filtering)
        var textContent: String? = nil
        var isUrl = false
        
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\\rtf") {
                textContent = string
                isUrl = string.hasPrefix("http://") || string.hasPrefix("https://")
            }
        }
        
        if textContent == nil {
            if let rtfData = pasteboard.data(forType: .rtf) {
                textContent = convertRTFToPlainText(rtfData)
            }
        }
        
        if textContent == nil, let string = pasteboard.string(forType: .string), !string.isEmpty {
            if let stringData = string.data(using: .utf8) {
                textContent = convertRTFToPlainText(stringData) ?? string
            }
        }
        
        if let string = textContent, !string.isEmpty {
            let type: ClipboardContentType = isUrl ? .url : .text
            let item = ClipboardHistoryItem(
                id: UUID().uuidString,
                contentType: type,
                previewText: String(string.prefix(200)),
                fullText: string,
                mimeType: "text/plain",
                sourceApp: activeApp,
                timestamp: Date(),
                isPinned: false,
                isFavourite: false,
                sizeBytes: string.utf8.count
            )
            self.lastItem = item
            LinkOSLogger.shared.info("[ClipboardSync] [\(Int(Date().timeIntervalSince1970 * 1000))] [CLIP-\(item.id.prefix(6))] Emitted plain text clipboard update (\(item.sizeBytes) bytes)", category: .protocol_)
            if let payload = try? JSONEncoder().encode(item) {
                onClipboardChanged?(item, payload)
            }
            return
        }
        
        // 3. Image
        if let image = NSImage(pasteboard: pasteboard), let tiffData = image.tiffRepresentation {
            let item = ClipboardHistoryItem(
                id: UUID().uuidString,
                contentType: .image,
                previewText: "Image (\(Int(image.size.width))x\(Int(image.size.height)))",
                fullText: tiffData.base64EncodedString(),
                mimeType: "image/png",
                sourceApp: activeApp,
                timestamp: Date(),
                isPinned: false,
                isFavourite: false,
                sizeBytes: tiffData.count
            )
            self.lastItem = item
            LinkOSLogger.shared.info("[ClipboardSync] [\(Int(Date().timeIntervalSince1970 * 1000))] [CLIP-\(item.id.prefix(6))] Emitted image clipboard update (\(item.sizeBytes) bytes)", category: .protocol_)
            if let payload = try? JSONEncoder().encode(item) {
                onClipboardChanged?(item, payload)
            }
            return
        }
    }
    
    private func convertRTFToPlainText(_ rtfData: Data) -> String? {
        if let attributedString = try? NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attributedString.string
        }
        return nil
    }
}
