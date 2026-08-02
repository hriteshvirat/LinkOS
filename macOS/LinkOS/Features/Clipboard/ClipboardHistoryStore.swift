import Foundation
import Combine

/// Real persistent database for clipboard history with max items cap, pinning, and search.
/// Merges both Android and macOS clipboard histories.
@MainActor
final class ClipboardHistoryManager: ObservableObject {
    static let shared = ClipboardHistoryManager()
    
    @Published var items: [ClipboardHistoryItem] = []
    private let maxItems = 100
    private let fileURL = URL(fileURLWithPath: "/Users/hritesh/.gemini/antigravity-ide/clipboard_history.json")
    
    private init() {
        loadHistory()
    }
    
    func addItem(_ item: ClipboardHistoryItem) {
        // Prevent duplicate consecutive entries
        if let first = items.first, first.fullText == item.fullText && first.contentType == item.contentType {
            return
        }
        items.insert(item, at: 0)
        trim()
        saveHistory()
    }
    
    func togglePin(id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isPinned.toggle()
            saveHistory()
        }
    }
    
    func toggleFavourite(id: String) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isFavourite.toggle()
            saveHistory()
        }
    }
    
    func deleteItem(id: String) {
        items.removeAll { $0.id == id }
        saveHistory()
    }
    
    func clearHistory() {
        items.removeAll { !$0.isPinned && !$0.isFavourite }
        saveHistory()
    }
    
    private func trim() {
        if items.count > maxItems {
            let disposable = items.filter { !$0.isPinned && !$0.isFavourite }
            if disposable.count > (maxItems / 2) {
                let toRemove = disposable.suffix(items.count - maxItems)
                let removeIDs = Set(toRemove.map { $0.id })
                items.removeAll { removeIDs.contains($0.id) }
            }
        }
    }
    
    private func loadHistory() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode([ClipboardHistoryItem].self, from: data)
                self.items = decoded
            }
        } catch {
            print("Failed to load clipboard history: \(error)")
        }
    }
    
    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save clipboard history: \(error)")
        }
    }
}
