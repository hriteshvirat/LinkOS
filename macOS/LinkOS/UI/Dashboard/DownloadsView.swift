import SwiftUI
import QuickLookThumbnailing

struct DownloadItem: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let sizeBytes: Int64
    let modificationDate: Date
    var thumbnail: NSImage?
}

@MainActor
final class DownloadsManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    
    private let downloadsURL: URL
    private var timer: Timer?
    
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.downloadsURL = home.appendingPathComponent("Downloads/LinkOS")
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
        
        // Refresh on notification instead of polling — zero idle CPU footprint
        NotificationCenter.default.addObserver(forName: Notification.Name("LinkOSFileReceived"), object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        
        refresh()
    }
    
    func refresh() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        
        var newItems: [DownloadItem] = []
        for fileURL in files {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = Int64(values.fileSize ?? 0)
            let modDate = values.contentModificationDate ?? Date()
            
            if let existing = items.first(where: { $0.path == fileURL.path && $0.modificationDate == modDate }) {
                newItems.append(existing)
            } else {
                newItems.append(DownloadItem(
                    id: fileURL.path,
                    name: fileURL.lastPathComponent,
                    path: fileURL.path,
                    sizeBytes: size,
                    modificationDate: modDate,
                    thumbnail: nil
                ))
            }
        }
        
        newItems.sort { $0.modificationDate > $1.modificationDate }
        self.items = newItems
        
        for index in 0..<self.items.count {
            if self.items[index].thumbnail == nil {
                let path = self.items[index].path
                generateThumbnail(for: path)
            }
        }
    }
    
    private func generateThumbnail(for path: String) {
        let url = URL(fileURLWithPath: path)
        let size = CGSize(width: 48, height: 48)
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: [.thumbnail, .icon])
        
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, error in
            guard let self = self, let cgImage = representation?.cgImage else { return }
            let nsImage = NSImage(cgImage: cgImage, size: size)
            
            DispatchQueue.main.async {
                // Find item by path rather than index — safe against reorder/refresh races
                if let idx = self.items.firstIndex(where: { $0.path == path }) {
                    self.items[idx].thumbnail = nsImage
                }
            }
        }
    }
    
    func deleteItem(_ item: DownloadItem) {
        try? FileManager.default.removeItem(atPath: item.path)
        refresh()
    }
    
    func renameItem(_ item: DownloadItem, newName: String) {
        let currentURL = URL(fileURLWithPath: item.path)
        let destURL = currentURL.deletingLastPathComponent().appendingPathComponent(newName)
        try? FileManager.default.moveItem(at: currentURL, to: destURL)
        refresh()
    }
}

struct DownloadsView: View {
    @StateObject private var manager = DownloadsManager()
    @ObservedObject var queueManager = FileTransferQueueManager.shared
    @State private var renamingItemId: String? = nil
    @State private var renameText = ""
    @State private var hoverItemId: String? = nil
    
    @State private var isGridView = false
    @State private var selectedTab = "Files" // "Files" vs "History"
    @State private var historySearchQuery = ""
    @State private var historyFilter = "all" // "all", "completed", "active", "failed"
    
    private var filteredHistory: [TransferItem] {
        queueManager.activeTransfers.filter { item in
            if !historySearchQuery.isEmpty {
                guard item.fileName.localizedCaseInsensitiveContains(historySearchQuery) else { return false }
            }
            switch historyFilter {
            case "completed":
                return item.status == "completed"
            case "active":
                return item.status == "transferring" || item.status == "paused" || item.status == "pending"
            case "failed":
                return item.status == "failed" || item.status == "cancelled"
            default:
                return true
            }
        }
        .sorted { $0.lastModified > $1.lastModified }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Text("Downloads")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                
                Spacer()
                
                // Tab Selection
                Picker("", selection: $selectedTab) {
                    Text("Files").tag("Files")
                    Text("Transfer History").tag("History")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(.horizontal, 10)
                
                if selectedTab == "Files" {
                    Button(action: {
                        isGridView.toggle()
                    }) {
                        Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(isGridView ? "List View" : "Grid View")
                }
                
                Button(action: {
                    let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/LinkOS")
                    NSWorkspace.shared.open(downloads)
                }) {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(hex: "0D0F13"))
            
            Divider().opacity(0.1)
            
            if selectedTab == "History" {
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.gray)
                        TextField("Search history...", text: $historySearchQuery)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                        if !historySearchQuery.isEmpty {
                            Button(action: { historySearchQuery = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                    
                    Picker("", selection: $historyFilter) {
                        Text("All").tag("all")
                        Text("Completed").tag("completed")
                        Text("Active").tag("active")
                        Text("Failed").tag("failed")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 110)
                    .cornerRadius(6)
                    
                    Button(action: { queueManager.clearHistory() }) {
                        Text("Clear History")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!queueManager.activeTransfers.contains(where: { $0.status == "completed" || $0.status == "failed" || $0.status == "cancelled" }))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(hex: "0D0F13").opacity(0.5))
                Divider().opacity(0.06)
            }
            
            ScrollView {
                if selectedTab == "Files" {
                    if manager.items.isEmpty {
                        emptyView(title: "No files received yet", subtitle: "Files sent from Android will appear here")
                    } else if isGridView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 16)], spacing: 16) {
                            ForEach(manager.items) { item in
                                gridItemView(item)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(manager.items) { item in
                                downloadRow(item)
                                Divider().opacity(0.04)
                            }
                        }
                        .background(Color.white.opacity(0.01))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.04), lineWidth: 1))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                } else {
                    let history = filteredHistory
                    if history.isEmpty {
                        if queueManager.activeTransfers.isEmpty {
                            emptyView(title: "No transfer history", subtitle: "Active and completed transfers will list here")
                        } else {
                            emptyView(title: "No matching transfers", subtitle: "Try adjusting your search or filters")
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(history) { item in
                                historyRow(item)
                                Divider().opacity(0.04)
                            }
                        }
                        .background(Color.white.opacity(0.01))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.04), lineWidth: 1))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }
            }
        }
        .background(Color(hex: "07080A"))
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LinkOSFileReceived"))) { _ in
            manager.refresh()
        }
    }
    
    @ViewBuilder
    private func emptyView(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.gray)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.gray)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.gray.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
    
    @ViewBuilder
    private func gridItemView(_ item: DownloadItem) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.02))
                    .frame(width: 80, height: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
                
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .cornerRadius(6)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color(hex: "06B6D4"))
                }
            }
            
            VStack(spacing: 2) {
                if renamingItemId == item.id {
                    TextField("Rename", text: $renameText, onCommit: {
                        if !renameText.isEmpty && renameText != item.name {
                            manager.renameItem(item, newName: renameText)
                        }
                        renamingItemId = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                } else {
                    Text(item.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 4)
        }
        .frame(width: 100, height: 130)
        .padding(6)
        .background(hoverItemId == item.id ? Color.white.opacity(0.04) : Color.clear)
        .cornerRadius(12)
        .onHover { hovering in
            hoverItemId = hovering ? item.id : nil
        }
        .contextMenu {
            Button("Open") {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            }
            Button("Rename") {
                renameText = item.name
                renamingItemId = item.id
            }
            Divider()
            Button("Delete", role: .destructive) {
                manager.deleteItem(item)
            }
        }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
        .onDrag {
            return NSItemProvider(contentsOf: URL(fileURLWithPath: item.path)) ?? NSItemProvider()
        }
    }
    
    @ViewBuilder
    private func downloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .cornerRadius(4)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.gray)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if renamingItemId == item.id {
                    TextField("Rename", text: $renameText, onCommit: {
                        if !renameText.isEmpty && renameText != item.name {
                            manager.renameItem(item, newName: renameText)
                        }
                        renamingItemId = nil
                    })
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                } else {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file) + " • " + formatDate(item.modificationDate))
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            
            Spacer()
            
            if hoverItemId == item.id {
                Button(action: {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                }) {
                    Image(systemName: "arrow.up.right.square.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(hoverItemId == item.id ? Color.white.opacity(0.02) : Color.clear)
        .onHover { isHovering in
            hoverItemId = isHovering ? item.id : nil
        }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
        .contextMenu {
            Button("Open") {
                NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            }
            Button("Rename") {
                renameText = item.name
                renamingItemId = item.id
            }
            Divider()
            Button("Delete", role: .destructive) {
                manager.deleteItem(item)
            }
        }
        .onDrag {
            return NSItemProvider(contentsOf: URL(fileURLWithPath: item.path)) ?? NSItemProvider()
        }
    }
    
    @ViewBuilder
    private func historyRow(_ item: TransferItem) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16))
                .foregroundStyle(Color(hex: "06B6D4"))
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                
                let percent = item.totalSize > 0 ? Double(item.bytesTransferred) / Double(item.totalSize) : 0.0
                let transferredStr = ByteCountFormatter.string(fromByteCount: item.bytesTransferred, countStyle: .file)
                let totalStr = ByteCountFormatter.string(fromByteCount: item.totalSize, countStyle: .file)
                
                HStack(spacing: 8) {
                    Text("\(transferredStr) of \(totalStr)")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    
                    ProgressView(value: percent)
                        .progressViewStyle(.linear)
                        .frame(width: 100)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.status.capitalized)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor(item.status).opacity(0.15))
                    .foregroundStyle(statusColor(item.status))
                    .cornerRadius(6)
                
                Text(item.lastModified, style: .time)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "failed": return .red
        case "transferring": return .blue
        case "paused", "pending": return .yellow
        default: return .gray
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
