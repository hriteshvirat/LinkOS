import SwiftUI
import AppKit

/// Rich, Premium Universal Clipboard Management View for macOS.
/// Connects to persistent ClipboardHistoryManager database, offering:
/// - Pinned, Favourites, and All filter tabs.
/// - Detailed side-docked Preview Pane for Text, URLs, Images, and Files.
/// - Keyboard shortcuts (Arrow keys for navigation, Cmd+C to copy, Delete/Backspace to remove).
/// - Bulk Delete and Multi-Selection support.
/// - Dynamic size indicators and file indicators.
struct UniversalClipboardView: View {
    @ObservedObject var manager = ClipboardHistoryManager.shared
    
    @State private var searchQuery: String = ""
    @State private var deviceFilter: String = "All" // "All", "Android", "macOS"
    @State private var tabFilter: String = "All" // "All", "Pinned", "Starred"
    
    @State private var selectedItemId: String? = nil
    @State private var selectedIds = Set<String>() // For bulk operations
    @State private var copiedNotice: String? = nil
    
    // Focus helper for keyboard shortcuts
    @FocusState private var isListFocused: Bool
    
    var filteredItems: [ClipboardHistoryItem] {
        var result = manager.items
        
        // Filter by tab type
        if tabFilter == "Pinned" {
            result = result.filter { $0.isPinned }
        } else if tabFilter == "Starred" {
            result = result.filter { $0.isFavourite }
        }
        
        // Apply search query
        if !searchQuery.isEmpty {
            let lower = searchQuery.lowercased()
            result = result.filter {
                $0.previewText.lowercased().contains(lower) ||
                ($0.fullText?.lowercased().contains(lower) ?? false)
            }
        }
        
        // Apply device filter
        if deviceFilter == "Android" {
            result = result.filter { $0.sourceApp?.contains("Android") ?? false }
        } else if deviceFilter == "macOS" {
            result = result.filter { !($0.sourceApp?.contains("Android") ?? false) }
        }
        
        return result
    }
    
    // Stats computations
    var totalItemsCount: Int { manager.items.count }
    var databaseSizeString: String {
        let bytes = manager.items.reduce(0) { $0 + $1.sizeBytes }
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
        }
    }
    
    var selectedItem: ClipboardHistoryItem? {
        if let selectedItemId = selectedItemId {
            return manager.items.first(where: { $0.id == selectedItemId })
        }
        return filteredItems.first
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Left Pane: History timeline & Controls
            VStack(alignment: .leading, spacing: 14) {
                // Headline & Timeline Stats
                HStack(spacing: 12) {
                    statsIndicator(title: "Database Size", value: databaseSizeString)
                    statsIndicator(title: "Total Synced", value: "\(totalItemsCount) entries")
                }
                
                // Timeline Filter Tabs (All, Pinned, Starred)
                HStack(spacing: 8) {
                    tabButton(title: "All", icon: "tray.2")
                    tabButton(title: "Pinned", icon: "pin.fill")
                    tabButton(title: "Starred", icon: "star.fill")
                    Spacer()
                }
                .padding(.vertical, 4)
                
                // Search & Filter Header
                HStack(spacing: 8) {
                    // Search Textfield
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.gray)
                        TextField("Search clipboard database...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: "16181D")))
                    
                    // Device Filter Selector
                    Picker("", selection: $deviceFilter) {
                        Text("All Devices").tag("All")
                        Text("📱 Phone").tag("Android")
                        Text("💻 Mac").tag("macOS")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }
                
                // Bulk Selection Actions Bar
                HStack {
                    if !selectedIds.isEmpty {
                        Text("\(selectedIds.count) items selected")
                            .font(.caption2)
                            .foregroundStyle(Color(hex: "3B82F6"))
                            .fontWeight(.semibold)
                        
                        Spacer()
                        
                        Button("Copy Selected") {
                            bulkCopy()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.3)))
                        
                        Button("Delete Selected") {
                            bulkDelete()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.3)))
                    } else {
                        Button("Select All Unpinned") {
                            selectAllUnpinned()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.gray)
                        
                        Spacer()
                        
                        Button("Clear Unpinned") {
                            manager.clearHistory()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.7))
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                
                // Copy/Action feedback banners
                if let notice = copiedNotice {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.white)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.15)))
                    .transition(.opacity)
                }
                
                // Timeline List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if filteredItems.isEmpty {
                                VStack(spacing: 12) {
                                    Spacer().frame(height: 60)
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.gray.opacity(0.5))
                                    Text("No items match filters")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }
                            } else {
                                ForEach(filteredItems) { item in
                                    clipboardRow(item)
                                        .onTapGesture {
                                            selectedItemId = item.id
                                            isListFocused = true
                                        }
                                }
                            }
                        }
                        .padding(2)
                    }
                }
                .focused($isListFocused)
                .onKeyPress(phases: .down) { press in
                    handleKeyPress(press)
                }
            }
            .padding(20)
            
            Divider()
                .opacity(0.1)
            
            // Right Pane: Detail Preview Card (Interactive)
            previewPane
                .frame(width: 320)
                .background(Color(hex: "090A0D"))
        }
        .onAppear {
            isListFocused = true
        }
    }
    
    // MARK: - Subcomponents
    
    private func statsIndicator(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: "3B82F6").opacity(0.2))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                Text(value)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "121419")))
    }
    
    private func tabButton(title: String, icon: String) -> some View {
        let active = tabFilter == title
        return Button(action: {
            withAnimation(.spring(response: 0.3)) {
                tabFilter = title
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color(hex: "3B82F6") : Color.clear)
            )
            .foregroundStyle(active ? .white : .gray)
        }
        .buttonStyle(.plain)
    }
    
    private func clipboardRow(_ item: ClipboardHistoryItem) -> some View {
        let isSelected = selectedItem?.id == item.id
        let isMultiSelected = selectedIds.contains(item.id)
        
        return HStack(spacing: 12) {
            // Checkbox for bulk delete selection
            Button(action: {
                toggleSelection(item.id)
            }) {
                Image(systemName: isMultiSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(isMultiSelected ? Color(hex: "3B82F6") : .gray)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.previewText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    // Content Badge Type
                    Text(contentBadgeLabel(item.contentType))
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(contentBadgeColor(item.contentType).opacity(0.15))
                        .foregroundStyle(contentBadgeColor(item.contentType))
                        .cornerRadius(3)
                    
                    // Device Origin
                    let isAndroid = item.sourceApp?.contains("Android") ?? false
                    Text(isAndroid ? "Phone" : "Mac")
                        .font(.system(size: 8))
                        .foregroundStyle(.gray)
                    
                    // Size representation
                    Text(sizeFormatted(item.sizeBytes))
                        .font(.system(size: 8))
                        .foregroundStyle(.gray)
                }
            }
            
            Spacer()
            
            // Row action buttons
            HStack(spacing: 10) {
                Button(action: {
                    manager.togglePin(id: item.id)
                }) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(item.isPinned ? Color(hex: "F59E0B") : .gray)
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    manager.toggleFavourite(id: item.id)
                }) {
                    Image(systemName: item.isFavourite ? "star.fill" : "star")
                        .foregroundStyle(item.isFavourite ? Color(hex: "EC4899") : .gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color(hex: "3B82F6").opacity(0.15) : Color(hex: "121419"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color(hex: "3B82F6").opacity(0.4) : Color.white.opacity(0.04), lineWidth: 1)
        )
    }
    
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DETAILS PREVIEW")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.gray)
                .padding(.top, 20)
                .padding(.horizontal, 16)
            
            if let item = selectedItem {
                VStack(alignment: .leading, spacing: 14) {
                    // Content Header
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contentBadgeLabel(item.contentType) + " Entry")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Copied from \(item.sourceApp ?? "Unknown Device")")
                                .font(.caption)
                                .foregroundStyle(.gray)
                        }
                        Spacer()
                    }
                    
                    // Rendered Content Box
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if item.contentType == .image {
                                Image(systemName: "photo.fill")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.gray)
                                    .frame(maxWidth: .infinity, minHeight: 120)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.02)))
                            } else {
                                Text(item.fullText ?? item.previewText)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.4)))
                    
                    // Action Buttons inside Preview
                    VStack(spacing: 8) {
                        Button(action: {
                            sendToAndroid(item)
                        }) {
                            HStack {
                                Image(systemName: "paperplane.fill")
                                Text("Send to Android")
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "06B6D4")))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        
                        HStack(spacing: 8) {
                            Button(action: {
                                copyToClipboard(item)
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text("Copy Locally")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                manager.togglePin(id: item.id)
                            }) {
                                Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                                    .frame(width: 32, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(item.isPinned ? Color(hex: "EAB308").opacity(0.3) : Color.white.opacity(0.1)))
                                    .foregroundStyle(item.isPinned ? Color(hex: "EAB308") : .white)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                manager.toggleFavourite(id: item.id)
                            }) {
                                Image(systemName: item.isFavourite ? "star.fill" : "star")
                                    .frame(width: 32, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(item.isFavourite ? Color(hex: "EAB308").opacity(0.3) : Color.white.opacity(0.1)))
                                    .foregroundStyle(item.isFavourite ? Color(hex: "EAB308") : .white)
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: {
                                manager.deleteItem(id: item.id)
                                selectedItemId = nil
                            }) {
                                Image(systemName: "trash.fill")
                                    .frame(width: 32, height: 26)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.2)))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if item.contentType == .url, let urlString = item.fullText, let url = URL(string: urlString) {
                            Button(action: {
                                NSWorkspace.shared.open(url)
                            }) {
                                HStack {
                                    Image(systemName: "safari")
                                    Text("Open Link in Browser")
                                        .fontWeight(.medium)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Button(action: {
                            manager.deleteItem(id: item.id)
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Item")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(.gray.opacity(0.5))
                    Text("Select an item to inspect details")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    // MARK: - Actions & Helpers
    
    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }
    
    private func selectAllUnpinned() {
        let unpinnedIds = filteredItems.filter { !$0.isPinned }.map { $0.id }
        selectedIds = Set(unpinnedIds)
    }
    
    private func bulkDelete() {
        for id in selectedIds {
            manager.deleteItem(id: id)
        }
        selectedIds.removeAll()
        withAnimation {
            copiedNotice = "Successfully deleted selected entries."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedNotice = nil
        }
    }
    
    private func bulkCopy() {
        let contents = filteredItems
            .filter { selectedIds.contains($0.id) }
            .compactMap { $0.fullText ?? $0.previewText }
            .joined(separator: "\n\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contents, forType: .string)
        selectedIds.removeAll()
        
        withAnimation {
            copiedNotice = "Merged & copied selected items!"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedNotice = nil
        }
    }
    
    private func copyToClipboard(_ item: ClipboardHistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.fullText ?? item.previewText, forType: .string)
        withAnimation {
            copiedNotice = "Copied to clipboard!"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedNotice = nil
        }
    }
    
    private func sendToAndroid(_ item: ClipboardHistoryItem) {
        let text = item.fullText ?? item.previewText
        guard !text.isEmpty else { return }
        guard let textData = text.data(using: .utf8) else { return }
        
        Task {
            let msg = MessageRouter.createEvent(channel: "clipboard", payload: textData)
            await AppState.shared.connectionManager?.broadcast(msg)
            
            withAnimation {
                copiedNotice = "Replayed to Android!"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                copiedNotice = nil
            }
        }
    }
    
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let items = filteredItems
        guard !items.isEmpty else { return .ignored }
        
        let currentIndex = items.firstIndex(where: { $0.id == (selectedItemId ?? items.first?.id) }) ?? 0
        
        switch press.key {
        case .downArrow:
            let nextIndex = min(items.count - 1, currentIndex + 1)
            selectedItemId = items[nextIndex].id
            return .handled
        case .upArrow:
            let prevIndex = max(0, currentIndex - 1)
            selectedItemId = items[prevIndex].id
            return .handled
        case .delete, .escape:
            if let selectedItemId = selectedItemId {
                manager.deleteItem(id: selectedItemId)
                self.selectedItemId = nil
            }
            return .handled
        default:
            // Check modifier keys for Command + C copy shortcut
            if press.modifiers.contains(.command), press.key == KeyEquivalent("c") {
                if let activeItem = selectedItem {
                    copyToClipboard(activeItem)
                    return .handled
                }
            }
            return .ignored
        }
    }
    
    private func contentBadgeLabel(_ type: ClipboardContentType) -> String {
        switch type {
        case .text: return "TEXT"
        case .url: return "URL"
        case .image: return "IMAGE"
        case .fileReference: return "FILE"
        case .codeSnippet: return "CODE"
        case .richText: return "RTF"
        }
    }
    
    private func contentBadgeColor(_ type: ClipboardContentType) -> Color {
        switch type {
        case .text: return Color(hex: "3B82F6")
        case .url: return Color(hex: "06B6D4")
        case .image: return Color(hex: "10B981")
        case .fileReference: return Color(hex: "F59E0B")
        case .codeSnippet: return Color(hex: "8B5CF6")
        case .richText: return Color(hex: "EC4899")
        }
    }
    
    private func sizeFormatted(_ sizeBytes: Int) -> String {
        if sizeBytes < 1024 {
            return "\(sizeBytes) B"
        } else {
            return String(format: "%.1f KB", Double(sizeBytes) / 1024.0)
        }
    }
}
