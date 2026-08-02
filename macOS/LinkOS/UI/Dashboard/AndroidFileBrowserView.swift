import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import QuickLook

private func formatModificationDate(_ ms: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

struct AndroidFileBrowserView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("android_file_browser_view_mode") private var viewMode = "list"
    @State private var searchQuery = ""
    @State private var newFolderName = ""
    @State private var showCreateFolderAlert = false
    @State private var uploadHovered = false
    @State private var isDragOverUpload = false
    
    @State private var selectedItem: FileItemInfo? = nil
    @FocusState private var isBrowserFocused: Bool
    @State private var showRenameAlert = false
    @State private var renameQuery = ""
    @State private var showInfoSheet = false
    @State private var previewURL: URL? = nil
    
    var filteredFiles: [FileItemInfo] {
        let baseFiles = searchQuery.isEmpty
            ? appState.remoteFiles
            : appState.remoteFiles.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        
        return baseFiles.sorted { a, b in
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            if a.modificationDateMs != b.modificationDateMs {
                return a.modificationDateMs > b.modificationDateMs
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header Action Bar
                HStack(spacing: 12) {
                    // Back Button
                    Button(action: {
                        Task {
                            await navigateUp()
                        }
                    }) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.remoteCurrentPath == "/" || appState.remoteCurrentPath == "~" || appState.remoteCurrentPath.isEmpty)
                    
                    // Current Path Breadcrumb Bar
                    Text(getDisplayPath(appState.remoteCurrentPath))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                    
                    // View Mode Toggle Segmented Picker
                    Picker("", selection: $viewMode) {
                        Image(systemName: "list.bullet").tag("list")
                        Image(systemName: "square.grid.2x2").tag("grid")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 70)
                    
                    // Show/Hide Hidden Files Toggle
                    Button(action: {
                        appState.showHiddenFiles.toggle()
                        Task {
                            await loadDirectory(at: appState.remoteCurrentPath)
                        }
                    }) {
                        Image(systemName: appState.showHiddenFiles ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(appState.showHiddenFiles ? Color(hex: "6366F1") : .white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .help("Toggle Hidden Files (Cmd + Shift + .)")
                    
                    // Action Buttons
                    Button(action: { showCreateFolderAlert = true }) {
                        Label("New Folder", systemImage: "folder.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { triggerFileUploadSelector() }) {
                        HStack(spacing: 6) {
                            Image(systemName: isDragOverUpload ? "arrow.down.doc.fill" : "arrow.up.doc.fill")
                                .font(.system(size: 12, weight: .bold))
                            Text(isDragOverUpload ? "Drop File Here" : "Upload")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "6366F1"), Color(hex: "3B82F6")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .brightness((uploadHovered || isDragOverUpload) ? 0.08 : 0)
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(isDragOverUpload ? 0.8 : 0.0), lineWidth: 2)
                                .scaleEffect(isDragOverUpload ? 1.05 : 1.0)
                                .animation(isDragOverUpload ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: isDragOverUpload)
                        )
                        .shadow(color: Color(hex: "6366F1").opacity((uploadHovered || isDragOverUpload) ? 0.6 : 0.3), radius: (uploadHovered || isDragOverUpload) ? 12 : 6, y: 3)
                        .scaleEffect((uploadHovered || isDragOverUpload) ? 1.05 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: uploadHovered || isDragOverUpload)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in uploadHovered = hovering }
                    .onDrop(of: [.fileURL, .item], delegate: AndroidFileDropDelegate(isTargeted: $isDragOverUpload) { urls in
                        for url in urls {
                            let gotAccess = url.startAccessingSecurityScopedResource()
                            DispatchQueue.main.async {
                                Task {
                                    await checkAndUploadLocalFile(url)
                                    if gotAccess {
                                        url.stopAccessingSecurityScopedResource()
                                    }
                                }
                            }
                        }
                    })
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(Color(hex: "0D0F13"))
                
                Divider().opacity(0.1)
                
                // Search & Filters
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.gray)
                    TextField("Search Android storage...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .font(.system(size: 13))
                }
                .padding(10)
                .background(Color.white.opacity(0.03))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                
                // File Explorer Content Grid / List
                ScrollView {
                    if filteredFiles.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundStyle(.gray)
                            Text("No items found in this directory")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.gray)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        if viewMode == "list" {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredFiles) { item in
                                    FileRowItem(item: item, selectedItem: $selectedItem, onAction: handleFileAction) {
                                        openItem(item)
                                    }
                                    
                                    Divider().opacity(0.04)
                                }
                            }
                            .background(Color.white.opacity(0.01))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.04), lineWidth: 1))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 16) {
                                ForEach(filteredFiles) { item in
                                    FileGridItem(item: item, selectedItem: $selectedItem, onAction: handleFileAction) {
                                        openItem(item)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .focusable()
                .focusEffectDisabled()
                .focused($isBrowserFocused)
                .onKeyPress(phases: .down) { press in
                    guard let item = selectedItem else { return .ignored }
                    
                    switch press.key {
                    case .space:
                        quickLookItem(item)
                        return .handled
                        
                    case .return:
                        selectedItem = item
                        renameQuery = item.name
                        showRenameAlert = true
                        return .handled
                        
                    case .delete:
                        deleteItem(item)
                        selectedItem = nil
                        return .handled
                        
                    default:
                        break
                    }
                    
                    if press.modifiers.contains(.command) {
                        switch press.key {
                        case .init("c"):
                            copyItem(item)
                            return .handled
                        case .init("v"):
                            pasteItem(destinationFolder: appState.remoteCurrentPath)
                            return .handled
                        case .init("d"):
                            duplicateItem(item)
                            return .handled
                        default:
                            break
                        }
                    }
                    
                    return .ignored
                }
                .onTapGesture {
                    isBrowserFocused = true
                    selectedItem = nil
                }
                .onDrop(of: [.fileURL, .item], delegate: AndroidFileDropDelegate(isTargeted: nil) { urls in
                    for url in urls {
                        let gotAccess = url.startAccessingSecurityScopedResource()
                        DispatchQueue.main.async {
                            Task {
                                await checkAndUploadLocalFile(url)
                                if gotAccess {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                        }
                    }
                })
            }
            .onAppear {
                Task {
                    await loadDirectory(at: "~")
                }
            }
            .sheet(isPresented: $showCreateFolderAlert) {
                VStack(spacing: 16) {
                    Text("Create Folder")
                        .font(.headline)
                    
                    TextField("Folder Name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                    
                    HStack {
                        Button("Cancel") {
                            showCreateFolderAlert = false
                            newFolderName = ""
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Create") {
                            let fullPath = appState.remoteCurrentPath + "/" + newFolderName
                            Task {
                                if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                                    await plugin.requestRemoteOperation(action: "create_folder", source: fullPath)
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
                                }
                            }
                            showCreateFolderAlert = false
                            newFolderName = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(width: 300, height: 160)
            }
            .sheet(isPresented: $showRenameAlert) {
                VStack(spacing: 16) {
                    Text("Rename Item")
                        .font(.headline)
                    
                    TextField("Name", text: $renameQuery)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                    
                    HStack {
                        Button("Cancel") {
                            showRenameAlert = false
                            renameQuery = ""
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Rename") {
                            if let item = selectedItem {
                                let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
                                let dest = parent + "/" + renameQuery
                                Task {
                                    if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                                        await plugin.requestRemoteOperation(action: "rename", source: item.path, destination: dest)
                                        try? await Task.sleep(nanoseconds: 500_000_000)
                                        await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
                                    }
                                }
                            }
                            showRenameAlert = false
                            renameQuery = ""
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(width: 300, height: 160)
            }
            .sheet(isPresented: $showInfoSheet) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("File Info")
                        .font(.headline)
                    
                    if let item = selectedItem {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow {
                                Text("Name:")
                                    .fontWeight(.bold)
                                Text(item.name)
                            }
                            GridRow {
                                Text("Type:")
                                    .fontWeight(.bold)
                                Text(item.isDirectory ? "Folder" : "File")
                            }
                            if !item.isDirectory {
                                GridRow {
                                    Text("Size:")
                                        .fontWeight(.bold)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file))
                                }
                            }
                            GridRow {
                                Text("Modified:")
                                    .fontWeight(.bold)
                                Text(formatModificationDate(item.modificationDateMs))
                            }
                            GridRow {
                                Text("Path:")
                                    .fontWeight(.bold)
                                Text(item.path)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    
                    Button("Close") {
                        showInfoSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding()
                .frame(width: 400)
            }
            
            if appState.isDownloadingFile {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 16) {
                    ProgressView(value: appState.fileDownloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                    Text("Transferring file... \(Int(appState.fileDownloadProgress * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "171A21")))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
        }
        .quickLookPreview($previewURL)
    }
    
    private func handleFileAction(item: FileItemInfo, action: String) {
        switch action {
        case "open": openItem(item)
        case "openWith": openWithItem(item)
        case "copy": copyItem(item)
        case "paste": pasteItem(destinationFolder: item.isDirectory ? item.path : appState.remoteCurrentPath)
        case "duplicate": duplicateItem(item)
        case "rename":
            selectedItem = item
            renameQuery = item.name
            showRenameAlert = true
        case "delete": deleteItem(item)
        case "quickLook": quickLookItem(item)
        case "getInfo":
            selectedItem = item
            showInfoSheet = true
        case "compress": compressItem(item)
        case "share": shareItem(item)
        case "saveToDownloads": saveToDownloads(item)
        case "copyPath": copyPathItem(item)
        case "copyName": copyNameItem(item)
        default: break
        }
    }
    
    private func openItem(_ item: FileItemInfo) {
        if item.isDirectory {
            Task {
                await loadDirectory(at: item.path)
            }
        } else {
            downloadFile(item)
        }
    }
    
    private func openWithItem(_ item: FileItemInfo) {
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                let tempURL = try? await plugin.downloadFileToTemp(remotePath: item.path, fileName: item.name, isDragOrPreview: true)
                if let url = tempURL {
                    let openPanel = NSOpenPanel()
                    openPanel.title = "Choose Application to Open \(item.name)"
                    openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
                    openPanel.canChooseFiles = true
                    openPanel.canChooseDirectories = false
                    openPanel.allowsMultipleSelection = false
                    if openPanel.runModal() == .OK, let appURL = openPanel.url {
                        let config = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
                    }
                }
            }
        }
    }
    
    private func copyItem(_ item: FileItemInfo) {
        appState.fileClipboardSourcePath = item.path
        appState.fileClipboardOperation = "copy"
        
        if item.isDirectory {
            // Internal copy paste works purely off appState.fileClipboardSourcePath, no local download needed.
            return
        }
        
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(item.name)
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        // 1. Write modern NSURL objects instantly
        pasteboard.writeObjects([tempURL as NSURL])
        
        // 2. Write legacy filenames plist for Slack/WhatsApp/Finder compatibility instantly
        pasteboard.setPropertyList([tempURL.path], forType: NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType"))
        
        LinkOSLogger.shared.info("[Copy] Instantly registered temporary copy path on system clipboard: \(tempURL.path)", category: .files)
        
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                do {
                    // Pre-download silently in the background
                    _ = try await plugin.downloadFileToSpecificPath(remotePath: item.path, toLocalURL: tempURL, isCopy: true, isDragOrPreview: true)
                    
                    // 3. If it's an image, wait for download to finish, then write the NSImage object
                    let ext = tempURL.pathExtension.lowercased()
                    if ["png", "jpg", "jpeg", "gif", "tiff", "bmp"].contains(ext) {
                        if let image = NSImage(contentsOf: tempURL) {
                            pasteboard.writeObjects([image])
                        }
                    }
                } catch {
                    LinkOSLogger.shared.error("[Copy] Failed to copy background download: \(error.localizedDescription)", category: .files)
                }
            }
        }
    }
    
    private func pasteItem(destinationFolder: String) {
        guard let source = appState.fileClipboardSourcePath else { return }
        let sourceName = URL(fileURLWithPath: source).lastPathComponent
        let dest = destinationFolder + "/" + sourceName
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                await plugin.requestRemoteOperation(action: "copy", source: source, destination: dest)
                try? await Task.sleep(nanoseconds: 500_000_000)
                await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
            }
        }
    }
    
    private func duplicateItem(_ item: FileItemInfo) {
        let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        let ext = URL(fileURLWithPath: item.path).pathExtension
        let nameWithoutExt = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
        let copyName = nameWithoutExt + " copy" + (ext.isEmpty ? "" : ".\(ext)")
        let dest = parent + "/" + copyName
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                await plugin.requestRemoteOperation(action: "copy", source: item.path, destination: dest)
                try? await Task.sleep(nanoseconds: 500_000_000)
                await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
            }
        }
    }
    
    private func deleteItem(_ item: FileItemInfo) {
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                await plugin.requestRemoteOperation(action: "delete", source: item.path)
                try? await Task.sleep(nanoseconds: 500_000_000)
                await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
            }
        }
    }
    
    private func quickLookItem(_ item: FileItemInfo) {
        guard !item.isDirectory else { return }
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                let tempURL = try? await plugin.downloadFileToTemp(remotePath: item.path, fileName: item.name, isDragOrPreview: true)
                if let url = tempURL {
                    await MainActor.run {
                        self.previewURL = url
                    }
                }
            }
        }
    }
    
    private func compressItem(_ item: FileItemInfo) {
        let parent = URL(fileURLWithPath: item.path).deletingLastPathComponent().path
        let dest = parent + "/" + item.name + ".zip"
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                await plugin.requestRemoteOperation(action: "compress", source: item.path, destination: dest)
                try? await Task.sleep(nanoseconds: 500_000_000)
                await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
            }
        }
    }
    
    private func shareItem(_ item: FileItemInfo) {
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                let tempURL = try? await plugin.downloadFileToTemp(remotePath: item.path, fileName: item.name, isDragOrPreview: true)
                if let url = tempURL {
                    await MainActor.run {
                        let picker = NSSharingServicePicker(items: [url])
                        if let window = NSApp.keyWindow {
                            picker.show(relativeTo: .zero, of: window.contentView ?? NSView(), preferredEdge: .minY)
                        }
                    }
                }
            }
        }
    }
    
    private func saveToDownloads(_ item: FileItemInfo) {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let dest = downloadsDir.appendingPathComponent(item.name)
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                try? await plugin.downloadFile(remotePath: item.path, toLocalURL: dest)
                let content = UNMutableNotificationContent()
                content.title = "Download Complete"
                content.body = "Saved \(item.name) to Downloads"
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
    }
    
    private func copyPathItem(_ item: FileItemInfo) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.path, forType: .string)
    }
    
    private func copyNameItem(_ item: FileItemInfo) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.name, forType: .string)
    }

    private func loadDirectory(at path: String) async {
        if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
            await plugin.requestRemoteDirectory(at: path)
        }
    }
    
    private func navigateUp() async {
        let path = appState.remoteCurrentPath
        let components = path.split(separator: "/")
        if components.isEmpty { return }
        
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        await loadDirectory(at: parentPath)
    }
    
    private func downloadFile(_ item: FileItemInfo) {
        LinkOSLogger.shared.info("Downloading file: \(item.path)", category: .files)
        Task {
            if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                await plugin.downloadRemoteFileFromAndroid(remotePath: item.path)
            }
        }
    }
    
    private func uploadLocalFile(_ url: URL) async {
        LinkOSLogger.shared.info("Uploading file: \(url.path)", category: .files)
        if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
            do {
                try await plugin.uploadLocalFileToAndroid(filePath: url.path, targetDirectory: appState.remoteCurrentPath)
                try? await Task.sleep(nanoseconds: 500_000_000)
                await plugin.requestRemoteDirectory(at: appState.remoteCurrentPath)
                
                let content = UNMutableNotificationContent()
                content.title = "Upload Complete"
                content.body = "✓ Uploaded \(url.lastPathComponent) to phone"
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
                try? await UNUserNotificationCenter.current().add(request)
            } catch {
                LinkOSLogger.shared.error("Upload failed: \(error.localizedDescription)", category: .files)
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Upload Failed"
                    alert.informativeText = "Could not upload '\(url.lastPathComponent)': \(error.localizedDescription)"
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }
    
    private func checkAndUploadLocalFile(_ url: URL) async {
        if url.path.hasPrefix(NSTemporaryDirectory()) {
            LinkOSLogger.shared.info("[Upload] Skipping upload for internal or temporary file path: \(url.path)", category: .files)
            return
        }
        
        let fileName = url.lastPathComponent
        if appState.remoteFiles.contains(where: { $0.name == fileName }) {
            let alert = NSAlert()
            alert.messageText = "File Already Exists"
            alert.informativeText = "A file or folder named '\(fileName)' already exists in this directory. Do you want to overwrite it?"
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let existingItem = appState.remoteFiles.first(where: { $0.name == fileName }),
                   let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                    await plugin.requestRemoteOperation(action: "delete", source: existingItem.path)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                await uploadLocalFile(url)
            }
        } else {
            await uploadLocalFile(url)
        }
    }
    
    private func triggerFileUploadSelector() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = true
        
        openPanel.begin { response in
            if response == .OK {
                let urls = openPanel.urls
                Task {
                    for url in urls {
                        await checkAndUploadLocalFile(url)
                    }
                }
            }
        }
    }

    private func getDisplayPath(_ path: String) -> String {
        if path == "/storage/emulated/0" {
            return "Internal Storage"
        }
        if path.hasPrefix("/storage/emulated/0/") {
            return path.replacingOccurrences(of: "/storage/emulated/0/", with: "Internal Storage/")
        }
        return path
    }
}

// MARK: - Row Item

struct FileRowItem: View {
    @EnvironmentObject var appState: AppState
    let item: FileItemInfo
    @Binding var selectedItem: FileItemInfo?
    let onAction: (FileItemInfo, String) -> Void
    let onClick: () -> Void
    @State private var isHovered = false
    
    var isMedia: Bool {
        let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "mp4", "mov", "mkv"].contains(ext)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if isMedia, let thumbnail = appState.remoteThumbnails[item.path] {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
                    .clipped()
            } else {
                let (iconName, iconColor) = getFileIconAndColor(for: item)
                Image(systemName: iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
                    .frame(width: 32, height: 32)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                
                HStack(spacing: 6) {
                    if !item.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file))
                        Text("•")
                    }
                    Text(formatModificationDate(item.modificationDateMs))
                }
                .font(.system(size: 11))
                .foregroundStyle(.gray)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            selectedItem?.id == item.id
                ? Color.blue.opacity(0.18)
                : (isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            selectedItem = item
        }
        .onTapGesture(count: 2) {
            onClick()
        }
        .onAppear {
            if isMedia && appState.remoteThumbnails[item.path] == nil {
                Task {
                    if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                        if let base64 = await plugin.requestRemoteThumbnail(for: item.path),
                           let data = Data(base64Encoded: base64),
                           let nsImage = NSImage(data: data) {
                            await MainActor.run {
                                appState.remoteThumbnails[item.path] = nsImage
                            }
                        }
                    }
                }
            }
        }
        .contextMenu {
            Button("Open") { onAction(item, "open") }
            Button("Open With...") { onAction(item, "openWith") }
            
            Divider()
            
            Button("Copy") { onAction(item, "copy") }
            if item.isDirectory {
                Button("Paste") { onAction(item, "paste") }
            }
            Button("Duplicate") { onAction(item, "duplicate") }
            Button("Rename...") { onAction(item, "rename") }
            Button("Delete") { onAction(item, "delete") }
            
            Divider()
            
            Button("Quick Look") { onAction(item, "quickLook") }
            Button("Get Info") { onAction(item, "getInfo") }
            Button("Compress") { onAction(item, "compress") }
            Button("Share") { onAction(item, "share") }
            
            Divider()
            
            Button("Save to Downloads") { onAction(item, "saveToDownloads") }
            Button("Copy Path") { onAction(item, "copyPath") }
            Button("Copy Name") { onAction(item, "copyName") }
        }
        .onDrag {
            let ext = (item.name as NSString).pathExtension
            let utType = UTType(filenameExtension: ext) ?? UTType.data
            
            let downloadTask = Task<URL, Error> {
                if let plugin = await AppState.shared.pluginManager?.getPlugin(FileSystemPlugin.self) {
                    return try await plugin.downloadFileToTemp(remotePath: item.path, fileName: item.name, isDragOrPreview: true)
                } else {
                    throw NSError(domain: "LinkOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Plugin not available"])
                }
            }
            
            let provider = NSItemProvider()
            provider.suggestedName = item.name
            
            provider.registerFileRepresentation(forTypeIdentifier: utType.identifier, fileOptions: [], visibility: .all) { completion in
                let task = Task {
                    do {
                        let tempURL = try await downloadTask.value
                        completion(tempURL, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                
                let progress = Progress(totalUnitCount: 100)
                progress.cancellationHandler = {
                    task.cancel()
                    downloadTask.cancel()
                }
                return progress
            }
            
            provider.registerDataRepresentation(forTypeIdentifier: "com.linkos.internal.android-file", visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
            
            return provider
        }
    }
}

// MARK: - Grid Item

struct FileGridItem: View {
    @EnvironmentObject var appState: AppState
    let item: FileItemInfo
    @Binding var selectedItem: FileItemInfo?
    let onAction: (FileItemInfo, String) -> Void
    let onClick: () -> Void
    @State private var isHovered = false
    
    var isMedia: Bool {
        let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "gif", "mp4", "mov", "mkv"].contains(ext)
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        selectedItem?.id == item.id
                            ? Color.blue.opacity(0.25)
                            : (isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                selectedItem?.id == item.id
                                    ? Color.blue
                                    : (isHovered ? Color.white.opacity(0.2) : Color.white.opacity(0.06)),
                                lineWidth: selectedItem?.id == item.id ? 2 : 1
                            )
                    )
                
                if isMedia, let thumbnail = appState.remoteThumbnails[item.path] {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .cornerRadius(8)
                        .clipped()
                } else {
                    let (iconName, iconColor) = getFileIconAndColor(for: item)
                    Image(systemName: iconName)
                        .font(.system(size: 36))
                        .foregroundStyle(iconColor)
                }
            }
            .frame(width: 90, height: 90)
            
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .frame(width: 100)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            selectedItem = item
        }
        .onTapGesture(count: 2) {
            onClick()
        }
        .contextMenu {
            Button("Open") { onAction(item, "open") }
            Button("Open With...") { onAction(item, "openWith") }
            
            Divider()
            
            Button("Copy") { onAction(item, "copy") }
            if item.isDirectory {
                Button("Paste") { onAction(item, "paste") }
            }
            Button("Duplicate") { onAction(item, "duplicate") }
            Button("Rename...") { onAction(item, "rename") }
            Button("Delete") { onAction(item, "delete") }
            
            Divider()
            
            Button("Quick Look") { onAction(item, "quickLook") }
            Button("Get Info") { onAction(item, "getInfo") }
            Button("Compress") { onAction(item, "compress") }
            Button("Share") { onAction(item, "share") }
            
            Divider()
            
            Button("Save to Downloads") { onAction(item, "saveToDownloads") }
            Button("Copy Path") { onAction(item, "copyPath") }
            Button("Copy Name") { onAction(item, "copyName") }
        }
        .onDrag {
            let ext = (item.name as NSString).pathExtension
            let utType = UTType(filenameExtension: ext) ?? UTType.data
            
            let downloadTask = Task<URL, Error> {
                if let plugin = await AppState.shared.pluginManager?.getPlugin(FileSystemPlugin.self) {
                    return try await plugin.downloadFileToTemp(remotePath: item.path, fileName: item.name, isDragOrPreview: true)
                } else {
                    throw NSError(domain: "LinkOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Plugin not available"])
                }
            }
            
            let provider = NSItemProvider()
            provider.suggestedName = item.name
            
            provider.registerFileRepresentation(forTypeIdentifier: utType.identifier, fileOptions: [], visibility: .all) { completion in
                let task = Task {
                    do {
                        let tempURL = try await downloadTask.value
                        completion(tempURL, true, nil)
                    } catch {
                        completion(nil, false, error)
                    }
                }
                
                let progress = Progress(totalUnitCount: 100)
                progress.cancellationHandler = {
                    task.cancel()
                    downloadTask.cancel()
                }
                return progress
            }
            
            provider.registerDataRepresentation(forTypeIdentifier: "com.linkos.internal.android-file", visibility: .all) { completion in
                completion(Data(), nil)
                return nil
            }
            
            return provider
        }
        .onAppear {
            if isMedia && appState.remoteThumbnails[item.path] == nil {
                Task {
                    if let plugin = await appState.pluginManager?.getPlugin(FileSystemPlugin.self) {
                        if let base64 = await plugin.requestRemoteThumbnail(for: item.path),
                           let data = Data(base64Encoded: base64),
                           let nsImage = NSImage(data: data) {
                            await MainActor.run {
                                appState.remoteThumbnails[item.path] = nsImage
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - File Icon and Color Helper

func getFileIconAndColor(for item: FileItemInfo) -> (String, Color) {
    if item.isDirectory {
        return ("folder.fill", Color(hex: "06B6D4"))
    }
    
    let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
    switch ext {
    case "png", "jpg", "jpeg", "webp", "gif", "heic":
        return ("photo.fill", Color(hex: "F59E0B"))
    case "mp4", "mov", "mkv", "avi":
        return ("video.fill", Color(hex: "F59E0B"))
    case "mp3", "wav", "flac", "m4a":
        return ("music.note", Color(hex: "10B981"))
    case "pdf":
        return ("doc.richtext.fill", Color(hex: "3B82F6"))
    case "zip", "rar", "7z", "tar", "gz":
        return ("doc.zipper", Color(hex: "8B5CF6"))
    case "txt", "rtf", "md":
        return ("doc.text.fill", Color(hex: "3B82F6"))
    case "dmg", "pkg", "iso":
        return ("shippingbox.fill", Color(hex: "EF4444"))
    case "app":
        return ("app.badge.fill", Color(hex: "EF4444"))
    default:
        return ("doc.fill", .gray)
    }
}





struct AndroidFileDropDelegate: DropDelegate {
    let isTargeted: Binding<Bool>?
    let onDropURLs: ([URL]) -> Void
    
    init(isTargeted: Binding<Bool>? = nil, onDropURLs: @escaping ([URL]) -> Void) {
        self.isTargeted = isTargeted
        self.onDropURLs = onDropURLs
    }
    
    func dropEntered(info: DropInfo) {
        isTargeted?.wrappedValue = true
    }
    
    func dropExited(info: DropInfo) {
        isTargeted?.wrappedValue = false
    }
    
    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: ["com.linkos.internal.android-file"]) {
            return false
        }
        return true
    }
    
    func performDrop(info: DropInfo) -> Bool {
        isTargeted?.wrappedValue = false
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let u = url {
                    onDropURLs([u])
                }
            }
        }
        return true
    }
}

private var filePromiseDelegateKey: UInt8 = 0

final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let remotePath: String
    let fileName: String
    
    init(remotePath: String, fileName: String) {
        self.remotePath = remotePath
        self.fileName = fileName
        super.init()
    }
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                if let plugin = await AppState.shared.pluginManager?.getPlugin(FileSystemPlugin.self) {
                    try await plugin.downloadFile(remotePath: remotePath, toLocalURL: url)
                    completionHandler(nil)
                } else {
                    completionHandler(NSError(domain: "LinkOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Plugin not available"]))
                }
            } catch {
                completionHandler(error)
            }
        }
    }
    
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return fileName
    }
}

extension NSFilePromiseProvider: @retroactive NSItemProviderWriting {
    public static var writableTypeIdentifiersForItemProvider: [String] {
        return [UTType.fileURL.identifier]
    }
    
    public func loadData(withTypeIdentifier typeIdentifier: String, forItemProviderCompletionHandler completionHandler: @escaping (Data?, Error?) -> Void) -> Progress? {
        completionHandler(nil, nil)
        return nil
    }
}
