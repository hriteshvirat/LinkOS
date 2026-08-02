import Foundation
import AppKit
import CryptoKit
import UserNotifications

struct FileTransferChunkPayload: Codable {
    let transferId: String
    let chunkIndex: Int
    let totalChunks: Int
    let offsetBytes: UInt64
    let chunkDataBase64: String
    let checksumSha256: String
    // totalSize is optional; included on the first chunk to enable pre-allocation
    let totalSize: Int64?

    init(transferId: String, chunkIndex: Int, totalChunks: Int, offsetBytes: UInt64,
         chunkDataBase64: String, checksumSha256: String, totalSize: Int64? = nil) {
        self.transferId = transferId; self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks; self.offsetBytes = offsetBytes
        self.chunkDataBase64 = chunkDataBase64; self.checksumSha256 = checksumSha256
        self.totalSize = totalSize
    }
}

/// Manages per-transfer FileHandle reuse.
/// One handle is opened per transferId on the first chunk and closed only on completion or cancellation.
/// This eliminates concurrent write races caused by opening a fresh handle per chunk.
final class FileTransferService {
    // Chunk size constant — benchmarked value. See walkthrough.md for benchmark results.
    private let chunkSize: Int = 4 * 1024 * 1024 // 4 MB chunk size for high-speed transfers

    // File handle pool: one handle per transferId.
    private let handleLock = NSLock()
    private var activeFileHandles: [String: FileHandle] = [:]

    func readChunks(filePath: String) throws -> [FileTransferChunkPayload] {
        let url = URL(fileURLWithPath: filePath)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let totalSize = data.count
        let totalChunks = Int(ceil(Double(totalSize) / Double(chunkSize)))
        let transferId = UUID().uuidString

        var chunks: [FileTransferChunkPayload] = []
        for i in 0..<totalChunks {
            let start = i * chunkSize
            let end = min(start + chunkSize, totalSize)
            let chunkData = data.subdata(in: start..<end)
            let checksum = SHA256.hash(data: chunkData).compactMap { String(format: "%02x", $0) }.joined()
            chunks.append(FileTransferChunkPayload(
                transferId: transferId, chunkIndex: i, totalChunks: totalChunks,
                offsetBytes: UInt64(start),
                chunkDataBase64: chunkData.base64EncodedString(),
                checksumSha256: checksum,
                totalSize: i == 0 ? Int64(totalSize) : nil
            ))
        }
        return chunks
    }

    /// Write a chunk to the destination file, reusing the FileHandle for the transferId.
    /// The file is pre-allocated to totalSize bytes on the first chunk to create a sparse file
    /// so subsequent seeks to any offset are safe regardless of chunk arrival order.
    func writeChunk(_ chunk: FileTransferChunkPayload, destinationPath: String, totalFileSize: Int64?) throws {
        guard let chunkData = Data(base64Encoded: chunk.chunkDataBase64) else { return }
        let calculated = SHA256.hash(data: chunkData).compactMap { String(format: "%02x", $0) }.joined()
        guard calculated == chunk.checksumSha256 else {
            throw NSError(domain: "FileTransferService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Chunk \(chunk.chunkIndex) checksum mismatch"])
        }

        let url = URL(fileURLWithPath: destinationPath)
        let fm = FileManager.default

        handleLock.lock()
        var handle = activeFileHandles[chunk.transferId]
        if handle == nil {
            // First chunk: create file and pre-allocate to totalSize to enable out-of-order writes
            if !fm.fileExists(atPath: destinationPath) {
                fm.createFile(atPath: destinationPath, contents: nil)
            }
            let newHandle = try FileHandle(forWritingTo: url)
            if let size = totalFileSize, size > 0 {
                // Pre-allocate file to full size; creates a sparse file so offset seeks work
                try newHandle.truncate(atOffset: UInt64(size))
            }
            activeFileHandles[chunk.transferId] = newHandle
            handle = newHandle
        }
        handleLock.unlock()

        guard let h = handle else { return }
        try h.seek(toOffset: chunk.offsetBytes)
        try h.write(contentsOf: chunkData)
        // Note: we do NOT synchronize/close here — that happens in closeHandle()
    }

    /// Close and remove the file handle for a transfer (on completion or cancellation).
    func closeHandle(for transferId: String) {
        handleLock.lock()
        let h = activeFileHandles.removeValue(forKey: transferId)
        handleLock.unlock()
        try? h?.synchronize()
        try? h?.close()
    }

    func cancelTransfer(transferId: String, destinationPath: String?) {
        closeHandle(for: transferId)
        if let path = destinationPath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

final class FileSystemPlugin: LinkOSPlugin {
    let pluginId = "files"
    let displayName = "Finder Browser & Transfer"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["files"]
    let requiredPermissions: Set<String> = ["FILE_READ", "FILE_WRITE", "FILE_DELETE"]
    
    private(set) var isActive = false
    private let fsService = FileSystemService()
    private let transferService = FileTransferService()
    private weak var connectionManager: ConnectionManager?
    private var activeTransferPaths: [String: String] = [:]
    private var transferIsCopy: [String: Bool] = [:]
    private var transferIsDragOrPreview: [String: Bool] = [:]
    // totalSizes: tracks declared total size per transferId for pre-allocation and resume identity checks
    private var activeTotalSizes: [String: Int64] = [:]
    private var receivedChunks = [String: Set<Int>]()
    private let receivedChunksLock = NSLock()
    private var downloadCompletions: [String: CheckedContinuation<URL, Error>] = [:]
    private let downloadCompletionsLock = NSLock()

    /// Cancel an in-progress transfer: close handle, delete partial file, clean up state.
    func cancelTransfer(id: String) {
        let path = activeTransferPaths[id]
        transferService.cancelTransfer(transferId: id, destinationPath: path)
        activeTransferPaths.removeValue(forKey: id)
        transferIsCopy.removeValue(forKey: id)
        transferIsDragOrPreview.removeValue(forKey: id)
        activeTotalSizes.removeValue(forKey: id)
        receivedChunksLock.lock()
        receivedChunks.removeValue(forKey: id)
        receivedChunksLock.unlock()
        
        Task {
            if let deviceId = await MainActor.run(body: { AppState.shared.activeConnectedDevice?.id }) {
                let cancelPayload = "{\"action\":\"cancel\",\"transferId\":\"\(id)\"}".data(using: .utf8)!
                let message = MessageRouter.createRequest(channel: "files", payload: cancelPayload)
                try? await connectionManager?.send(message, to: deviceId)
            }
        }
        downloadCompletionsLock.lock()
        if let continuation = downloadCompletions.removeValue(forKey: id) {
            continuation.resume(throwing: NSError(domain: "FileTransfer", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"]))
        }
        downloadCompletionsLock.unlock()
        Task { await MainActor.run { FileTransferQueueManager.shared.updateProgress(id: id, bytesTransferred: 0, status: "cancelled") } }
        LinkOSLogger.shared.info("[\(id)] CANCELLED partial file deleted=\(path ?? "none")", category: .files)
    }
    
    private func calculateFileSha256(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("FileSystemPlugin activated", category: .files)
    }
    
    func deactivate() async {
        isActive = false
        LinkOSLogger.shared.info("FileSystemPlugin deactivated", category: .files)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        if let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
           let action = json["action"] as? String, action == "file_received" {
            let activePath = await MainActor.run(body: { AppState.shared.remoteCurrentPath })
            if !activePath.isEmpty {
                await requestRemoteDirectory(at: activePath)
            }
            return
        }
        
        if message.type == .response, let correlationId = message.correlationId, !correlationId.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] {
                let status = (json["status"] as? String == "success")
                let details = String(data: message.payload, encoding: .utf8) ?? ""
                ResponseAwaiter.shared.resume(correlationId: correlationId, status: status, message: details)
            }
            return
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any] else { return }
        
        if let action = json["action"] as? String {
            if action == "list", var path = json["path"] as? String {
                if path == "~" || path == "" || path == "/" {
                    path = "/Users"
                }
                var files: [FileItemInfo] = []
                do {
                    files = try fsService.listDirectory(at: path, includeHidden: true)
                } catch {
                    LinkOSLogger.shared.error("[FileTransfer] [\(Int(Date().timeIntervalSince1970 * 1000))] ERROR: Failed to list directory at \(path): \(error.localizedDescription)", category: .files)
                }
                
                let resolvedPayload: [String: Any] = [
                    "currentPath": path,
                    "files": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(files)) as? [[String: Any]]) ?? []
                ]
                
                if let payloadData = try? JSONSerialization.data(withJSONObject: resolvedPayload),
                   let response = try? MessageRouter.createResponse(channel: "files", payload: payloadData, correlationId: message.correlationId) {
                    try? await connectionManager?.send(response, to: message.deviceId)
                }
            } else if action == "cancel" {
                guard let transferId = json["transferId"] as? String else { return }
                self.cancelTransfer(id: transferId)
            } else if action == "pause" {
                guard let transferId = json["transferId"] as? String else { return }
                await MainActor.run {
                    FileTransferQueueManager.shared.pauseTransfer(id: transferId)
                }
            } else if action == "resume" {
                guard let transferId = json["transferId"] as? String else { return }
                await MainActor.run {
                    FileTransferQueueManager.shared.resumeTransfer(id: transferId)
                }
            } else if action == "upload_chunk" {
                guard let transferId = json["transferId"] as? String,
                      let chunkIndex = json["chunkIndex"] as? Int,
                      let totalChunks = json["totalChunks"] as? Int,
                      let offsetBytes = json["offsetBytes"] as? UInt64,
                      let chunkDataBase64 = json["chunkDataBase64"] as? String,
                      let checksumSha256 = json["checksumSha256"] as? String,
                      let fileName = json["fileName"] as? String else { return }
                
                let chunk = FileTransferChunkPayload(
                    transferId: transferId,
                    chunkIndex: chunkIndex,
                    totalChunks: totalChunks,
                    offsetBytes: offsetBytes,
                    chunkDataBase64: chunkDataBase64,
                    checksumSha256: checksumSha256
                )
                
                let targetDirectory = json["targetDirectory"] as? String
                
                let homeDir = FileManager.default.homeDirectoryForCurrentUser
                var downloadsDir = homeDir.appendingPathComponent("Downloads/LinkOS")
                
                let activeTab = await MainActor.run(body: { AppState.shared.activeFeature })
                let activeLocalPath = await MainActor.run(body: { AppState.shared.localCurrentPath })
                
                if activeTab == .files && !activeLocalPath.isEmpty {
                    downloadsDir = URL(fileURLWithPath: activeLocalPath)
                } else if let targetDir = targetDirectory, !targetDir.isEmpty, targetDir != "~", targetDir != "/" {
                    var resolvedPath = targetDir
                    if resolvedPath.hasPrefix("~") {
                        resolvedPath = resolvedPath.replacingOccurrences(of: "~", with: homeDir.path)
                    }
                    downloadsDir = URL(fileURLWithPath: resolvedPath)
                }
                try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                
                var finalPath = activeTransferPaths[transferId]
                if finalPath == nil {
                    var targetURL = downloadsDir.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: targetURL.path) {
                        let nameWithoutExtension = targetURL.deletingPathExtension().lastPathComponent
                        let fileExtension = targetURL.pathExtension
                        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                        let testURL = downloadsDir.appendingPathComponent("\(nameWithoutExtension)_\(timestamp).\(fileExtension)")
                        targetURL = testURL
                    }
                    finalPath = targetURL.path
                    activeTransferPaths[transferId] = finalPath
                }
                
                do {
                    let chunkWriteStart = Date()
                    // Store total size on first chunk for pre-allocation
                    if chunkIndex == 0, let ts = json["totalSize"] as? Int64 {
                        activeTotalSizes[transferId] = ts
                    }
                    let totalFileSizeForAlloc = activeTotalSizes[transferId]
                    try transferService.writeChunk(chunk, destinationPath: finalPath!, totalFileSize: totalFileSizeForAlloc)
                    let writeMs = Int(Date().timeIntervalSince(chunkWriteStart) * 1000)

                    // Actual decoded byte count (not base64 length)
                    let actualChunkBytes = Int64(Data(base64Encoded: chunkDataBase64)?.count ?? chunkDataBase64.count)

                    receivedChunksLock.lock()
                    if receivedChunks[transferId] == nil {
                        receivedChunks[transferId] = Set<Int>()
                    }
                    receivedChunks[transferId]?.insert(chunkIndex)
                    let chunkSet = receivedChunks[transferId] ?? []
                    receivedChunksLock.unlock()

                    // Structured transfer log
                    LinkOSLogger.shared.info("[\(transferId)] CHUNK \(chunkIndex)/\(totalChunks - 1) offset=\(chunk.offsetBytes) time=\(writeMs)ms sha=ok", category: .files)

                    let responsePayload = "{\"status\":\"success\",\"transferId\":\"\(transferId)\",\"chunkIndex\":\(chunkIndex)}".data(using: .utf8)!
                    let response = MessageRouter.createResponse(channel: "files", payload: responsePayload, correlationId: message.correlationId)
                    try? await connectionManager?.send(response, to: message.deviceId)

                    let chunkIndexVal = chunkIndex
                    let totalChunksVal = totalChunks
                    // Use the declared totalSize or estimate from chunk count * actual chunk size
                    let totalSizeForProgress = activeTotalSizes[transferId] ?? (Int64(totalChunksVal) * actualChunkBytes)
                    await MainActor.run {
                        if chunkIndexVal == 0 {
                            FileTransferQueueManager.shared.addTransfer(id: transferId, fileName: fileName, totalSize: totalSizeForProgress, isUpload: false)
                        }
                        // Use actual byte count for accurate progress (not base64 inflated count)
                        let currentProgressBytes = min(Int64(chunkIndexVal + 1) * actualChunkBytes, totalSizeForProgress)
                        let status = (chunkIndexVal == totalChunksVal - 1) ? "verifying" : "transferring"
                        FileTransferQueueManager.shared.updateProgress(id: transferId, bytesTransferred: currentProgressBytes, status: status)
                    }
                    
                    if chunkSet.count == totalChunks {
                        var verificationPassed = true
                        var verificationErrorDetail = ""
                        
                        // 1. Verify size
                        if let expectedSize = json["totalSize"] as? Int64 {
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalPath!),
                               let actualSize = attrs[.size] as? Int64 {
                                if actualSize != expectedSize {
                                    verificationPassed = false
                                    verificationErrorDetail = "Size mismatch: expected \(expectedSize), got \(actualSize)"
                                }
                            } else {
                                verificationPassed = false
                                verificationErrorDetail = "Could not read file size attributes"
                            }
                        }
                        
                        // 2. Verify SHA256 checksum
                        if verificationPassed, let expectedSha = json["fileSha256"] as? String {
                            if let actualSha = self.calculateFileSha256(path: finalPath!) {
                                if actualSha.lowercased() != expectedSha.lowercased() {
                                    verificationPassed = false
                                    verificationErrorDetail = "SHA256 mismatch: expected \(expectedSha), got \(actualSha)"
                                }
                            } else {
                                verificationPassed = false
                                verificationErrorDetail = "Could not compute file checksum"
                            }
                        }
                        
                        if verificationPassed {
                            // Close the file handle cleanly before declaring success
                            self.transferService.closeHandle(for: transferId)
                            self.receivedChunksLock.lock()
                            self.receivedChunks.removeValue(forKey: transferId)
                            self.receivedChunksLock.unlock()
                            self.activeTransferPaths.removeValue(forKey: transferId)
                            self.activeTotalSizes.removeValue(forKey: transferId)

                            self.downloadCompletionsLock.lock()
                            if let continuation = self.downloadCompletions.removeValue(forKey: transferId) {
                                continuation.resume(returning: URL(fileURLWithPath: finalPath!))
                            }
                            self.downloadCompletionsLock.unlock()

                            LinkOSLogger.shared.info("[\(transferId)] COMPLETED path=\(finalPath!) sha256=match size=match", category: .files)

                            let isDragOrPreview = self.transferIsDragOrPreview.removeValue(forKey: transferId) ?? false
                            let isCopy = self.transferIsCopy[transferId] ?? false
                            if isCopy || !isDragOrPreview {
                                self.showTransferCompleteNotification(fileName: URL(fileURLWithPath: finalPath!).lastPathComponent, filePath: finalPath!, transferId: transferId)
                            } else {
                                self.transferIsCopy.removeValue(forKey: transferId)
                            }
                            NotificationCenter.default.post(name: Notification.Name("LinkOSFileReceived"), object: nil, userInfo: ["filePath": finalPath!])

                            let notifyPayload = "{\"action\":\"file_received\",\"path\":\"\(finalPath!)\"}".data(using: .utf8)!
                            let notifyMsg = MessageRouter.createEvent(channel: "files", payload: notifyPayload)
                            try? await connectionManager?.send(notifyMsg, to: message.deviceId)

                            let declaredTotal = self.activeTotalSizes[transferId] ?? totalSizeForProgress
                            await MainActor.run {
                                FileTransferQueueManager.shared.updateProgress(id: transferId, bytesTransferred: declaredTotal, status: "completed")
                            }
                        } else {
                            // Verification failed — close handle and delete corrupted partial file
                            self.transferService.closeHandle(for: transferId)
                            try? FileManager.default.removeItem(atPath: finalPath!)

                            self.receivedChunksLock.lock()
                            self.receivedChunks.removeValue(forKey: transferId)
                            self.receivedChunksLock.unlock()
                            self.activeTransferPaths.removeValue(forKey: transferId)
                            self.activeTotalSizes.removeValue(forKey: transferId)
                            self.transferIsCopy.removeValue(forKey: transferId)
                            self.transferIsDragOrPreview.removeValue(forKey: transferId)

                            self.downloadCompletionsLock.lock()
                            if let continuation = self.downloadCompletions.removeValue(forKey: transferId) {
                                continuation.resume(throwing: NSError(domain: "FileTransfer", code: -2,
                                    userInfo: [NSLocalizedDescriptionKey: "File verification failed: \(verificationErrorDetail)"]))
                            }
                            self.downloadCompletionsLock.unlock()

                            LinkOSLogger.shared.error("[\(transferId)] FAILED verification=\(verificationErrorDetail)", category: .files)

                            let errPayload = "{\"status\":\"error\",\"transferId\":\"\(transferId)\",\"chunkIndex\":\(chunkIndex),\"code\":\"ERR_VERIFICATION_FAILED\",\"message\":\"\(verificationErrorDetail)\"}".data(using: .utf8)!
                            let response = MessageRouter.createResponse(channel: "files", payload: errPayload, correlationId: message.correlationId)
                            try? await connectionManager?.send(response, to: message.deviceId)

                            await MainActor.run {
                                FileTransferQueueManager.shared.updateProgress(id: transferId, bytesTransferred: 0, status: "failed")
                            }
                        }
                    }
                } catch {
                    let errPayload = "{\"status\":\"error\",\"transferId\":\"\(transferId)\",\"chunkIndex\":\(chunkIndex),\"message\":\"\(error.localizedDescription)\"}".data(using: .utf8)!
                    let response = MessageRouter.createResponse(channel: "files", payload: errPayload, correlationId: message.correlationId)
                    try? await connectionManager?.send(response, to: message.deviceId)
                    
                    self.downloadCompletionsLock.lock()
                    if let continuation = self.downloadCompletions.removeValue(forKey: transferId) {
                        continuation.resume(throwing: error)
                    }
                    self.downloadCompletionsLock.unlock()
                    self.transferIsCopy.removeValue(forKey: transferId)
                    self.transferIsDragOrPreview.removeValue(forKey: transferId)
                    
                    let chunkIndexVal = chunkIndex
                    await MainActor.run {
                        FileTransferQueueManager.shared.updateProgress(id: transferId, bytesTransferred: Int64(chunkIndexVal) * Int64(chunkDataBase64.count), status: "failed")
                    }
                }
            } else if action == "operation",
                      let opType = json["operation_type"] as? String,
                      let source = json["source"] as? String {
                let dest = json["destination"] as? String
                do {
                    try fsService.performOperation(action: opType, sourcePath: source, destinationPath: dest)
                    let response = MessageRouter.createResponse(channel: "files", payload: "{\"status\":\"success\"}".data(using: .utf8)!, correlationId: message.correlationId)
                    try? await connectionManager?.send(response, to: message.deviceId)
                } catch {
                    let errPayload = "{\"status\":\"error\",\"message\":\"\(error.localizedDescription)\"}".data(using: .utf8)!
                    let response = MessageRouter.createResponse(channel: "files", payload: errPayload, correlationId: message.correlationId)
                    try? await connectionManager?.send(response, to: message.deviceId)
                }
            } else if action == "thumbnail",
                      let path = json["path"] as? String {
                if let tiffData = await fsService.generateThumbnail(for: path) {
                    // Convert TIFF to PNG for smaller size, then base64-encode
                    let imageData: Data
                    if let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                        imageData = pngData
                    } else {
                        imageData = tiffData
                    }
                    let base64String = imageData.base64EncodedString()
                    let jsonPayload = "{\"thumbnailBase64\":\"\(base64String)\"}".data(using: .utf8)!
                    let response = MessageRouter.createResponse(channel: "files", payload: jsonPayload, correlationId: message.correlationId)
                    try? await connectionManager?.send(response, to: message.deviceId)
                }
            } else if action == "download",
                      let path = json["path"] as? String {
                Task {
                    var resolvedPath = path
                    if resolvedPath.hasPrefix("~") {
                        resolvedPath = resolvedPath.replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
                    }
                    do {
                        try await self.uploadLocalFileToAndroid(filePath: resolvedPath, targetDirectory: "~")
                    } catch {
                        LinkOSLogger.shared.error("[FileTransfer] Failed to upload local file to Android: \(error.localizedDescription)", category: .files)
                    }
                }
            }
        } else {
            if let payloadStr = json["payload"] as? String {
                if payloadStr.hasPrefix("[") {
                    if let fileData = payloadStr.data(using: .utf8),
                       let fileList = try? JSONDecoder().decode([FileItemInfo].self, from: fileData) {
                        await MainActor.run {
                            AppState.shared.remoteFiles = fileList
                        }
                    }
                } else if let payloadJson = try? JSONSerialization.jsonObject(with: payloadStr.data(using: .utf8)!) as? [String: Any],
                           let status = payloadJson["status"] as? String {
                    NotificationCenter.default.post(name: NSNotification.Name("LinkOSFileOperationStatus"), object: nil, userInfo: ["status": status])
                }
            }
        }
    }
    
    private func showTransferCompleteNotification(fileName: String, filePath: String, transferId: String? = nil) {
        let content = UNMutableNotificationContent()
        let destFolder = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent
        let destParent = URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        
        let isCopy = transferId.flatMap { self.transferIsCopy.removeValue(forKey: $0) } ?? false
        
        if isCopy {
            content.title = "File Copied"
            content.body = "✓ \(fileName) copied to clipboard"
        } else if fileName.hasPrefix("clicked_pic_") {
            content.title = "Photo Captured"
            content.subtitle = "Saved to \(destParent)/\(destFolder)"
            content.body = "Ready to view."
        } else {
            content.title = "File Received"
            content.body = "✓ Saved to \(destFolder) (\(fileName))"
        }
        content.userInfo = ["file_path": filePath]
        content.sound = .default
        
        // Add image thumbnail attachment if possible
        let fileURL = URL(fileURLWithPath: filePath)
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic"]
        if fileName.hasPrefix("clicked_pic_") || imageExtensions.contains(fileURL.pathExtension.lowercased()) {
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + fileURL.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: fileURL, to: tempFileURL)
                if let attachment = try? UNNotificationAttachment(identifier: UUID().uuidString, url: tempFileURL, options: nil) {
                    content.attachments = [attachment]
                }
            } catch {
                LinkOSLogger.shared.error("Failed to copy file to temp dir for notification attachment: \(error)", category: .files)
            }
        }
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Mac initiated requests
    
    func requestRemoteDirectory(at path: String) async {
        guard let connectionManager else { return }
        let showHidden = await MainActor.run { AppState.shared.showHiddenFiles }
        let payload: [String: Any] = [
            "action": "list",
            "path": path,
            "showHidden": showHidden
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let msg = MessageRouter.createEvent(channel: "files", payload: data)
            await connectionManager.broadcast(msg)
            await MainActor.run {
                AppState.shared.remoteCurrentPath = path
            }
        }
    }
    
    func requestRemoteThumbnail(for path: String) async -> String? {
        guard let connectionManager = connectionManager,
              let activeDeviceId = await MainActor.run(body: { AppState.shared.activeConnectedDevice?.id }) else { return nil }
        
        let payload: [String: Any] = [
            "action": "thumbnail",
            "path": path
        ]
        
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let correlationId = UUID().uuidString
        let message = MessageRouter.createRequest(channel: "files", payload: payloadData, correlationId: correlationId)
        
        do {
            try await connectionManager.send(message, to: activeDeviceId)
            let (status, details) = await ResponseAwaiter.shared.awaitResponse(correlationId: correlationId, timeoutSec: 8.0)
            if status {
                if let responseData = details.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let base64 = json["thumbnailBase64"] as? String {
                    return base64
                }
            }
        } catch {
            LinkOSLogger.shared.error("Failed to request remote thumbnail: \(error.localizedDescription)", category: .files)
        }
        return nil
    }
    
    func requestRemoteOperation(action: String, source: String, destination: String? = nil) async {
        guard let connectionManager else { return }
        var payload: [String: Any] = [
            "action": "operation",
            "operation_type": action,
            "source": source
        ]
        if let dest = destination {
            payload["destination"] = dest
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let msg = MessageRouter.createEvent(channel: "files", payload: data)
            await connectionManager.broadcast(msg)
        }
    }
    
    func uploadLocalFileToAndroid(filePath: String, targetDirectory: String) async throws {
        guard let connectionManager = connectionManager else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active connection"])
        }
        
        var targetDir = targetDirectory
        let activeTab = await MainActor.run(body: { AppState.shared.activeFeature })
        let remotePath = await MainActor.run(body: { AppState.shared.remoteCurrentPath })
        if targetDir == "~" || targetDir.isEmpty || targetDir == "/" {
            if activeTab == .files && !remotePath.isEmpty {
                targetDir = remotePath
            } else {
                targetDir = "~"
            }
        }
        
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDir) else {
            throw NSError(domain: "FileTransfer", code: -2, userInfo: [NSLocalizedDescriptionKey: "File or folder does not exist"])
        }
        
        if isDir.boolValue {
            let dirURL = URL(fileURLWithPath: filePath)
            let parentURL = dirURL.deletingLastPathComponent()
            
            let enumerator = fileManager.enumerator(at: dirURL, includingPropertiesForKeys: [URLResourceKey.isRegularFileKey], options: [.skipsHiddenFiles])
            
            while let fileURL = enumerator?.nextObject() as? URL {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [URLResourceKey.isRegularFileKey]),
                      resourceValues.isRegularFile == true else { continue }
                
                let relativePath = fileURL.path.replacingOccurrences(of: parentURL.path + "/", with: "")
                try await uploadSingleFile(filePath: fileURL.path, relativeName: relativePath, targetDirectory: targetDir)
            }
        } else {
            let fileName = URL(fileURLWithPath: filePath).lastPathComponent
            try await uploadSingleFile(filePath: filePath, relativeName: fileName, targetDirectory: targetDir)
        }
    }
    
    private func uploadSingleFile(filePath: String, relativeName: String, targetDirectory: String) async throws {
        guard let connectionManager = connectionManager else {
            throw NSError(domain: "FileTransfer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active connection"])
        }
        
        guard let activeDeviceId = await MainActor.run(body: { AppState.shared.activeConnectedDevice?.id }) else {
            throw NSError(domain: "FileTransfer", code: -3, userInfo: [NSLocalizedDescriptionKey: "No active connected device"])
        }
        
        let attr = try FileManager.default.attributesOfItem(atPath: filePath)
        let modDate = attr[.modificationDate] as? Date ?? Date()
        let modDateMs = Int64(modDate.timeIntervalSince1970 * 1000)
        
        // Calculate file SHA256 before upload
        let fileData = try Data(contentsOf: URL(fileURLWithPath: filePath), options: .mappedIfSafe)
        let fileSha256 = SHA256.hash(data: fileData).compactMap { String(format: "%02x", $0) }.joined()
        
        let chunks = try transferService.readChunks(filePath: filePath)
        let totalChunks = chunks.count
        let transferId = chunks.first?.transferId ?? UUID().uuidString
        let totalSize = Int64(fileData.count)
        
        await MainActor.run {
            AppState.shared.isDownloadingFile = true
            AppState.shared.fileDownloadProgress = 0.0
            FileTransferQueueManager.shared.addTransfer(id: transferId, fileName: relativeName, totalSize: totalSize, isUpload: true)
        }
        
        let windowSize = ProtocolConstants.Transfer.windowSize // 16
        var bytesTransferred: Int64 = 0
        let bytesTransferredLock = NSLock()
        
        do {
            try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                var nextIndex = 0
                
                // Queue up initial window
                while nextIndex < min(windowSize, totalChunks) {
                    let chunkIdx = nextIndex
                    let chunk = chunks[chunkIdx]
                    group.addTask {
                        let sentBytes = try await self.sendChunkWithRetry(
                            chunk: chunk,
                            relativeName: relativeName,
                            targetDirectory: targetDirectory,
                            modDateMs: modDateMs,
                            fileSha256: fileSha256,
                            totalSize: totalSize,
                            activeDeviceId: activeDeviceId,
                            connectionManager: connectionManager
                        )
                        return (chunkIdx, sentBytes)
                    }
                    nextIndex += 1
                }
                
                var completedCount = 0
                for try await (_, sentBytes) in group {
                    completedCount += 1
                    
                    bytesTransferredLock.lock()
                    bytesTransferred += Int64(sentBytes)
                    let currentProgress = bytesTransferred
                    bytesTransferredLock.unlock()
                    
                    let progressRatio = Double(completedCount) / Double(totalChunks)
                    let statusVal = (completedCount == totalChunks) ? "completed" : "transferring"
                    
                    await MainActor.run {
                        AppState.shared.fileDownloadProgress = progressRatio
                        FileTransferQueueManager.shared.updateProgress(id: transferId, bytesTransferred: currentProgress, status: statusVal)
                    }
                    
                    if nextIndex < totalChunks {
                        let nextChunkIdx = nextIndex
                        let chunk = chunks[nextChunkIdx]
                        group.addTask {
                            let sentBytes = try await self.sendChunkWithRetry(
                                chunk: chunk,
                                relativeName: relativeName,
                                targetDirectory: targetDirectory,
                                modDateMs: modDateMs,
                                fileSha256: fileSha256,
                                totalSize: totalSize,
                                activeDeviceId: activeDeviceId,
                                connectionManager: connectionManager
                            )
                            return (nextChunkIdx, sentBytes)
                        }
                        nextIndex += 1
                    }
                }
            }
            
            await MainActor.run {
                AppState.shared.isDownloadingFile = false
                AppState.shared.fileDownloadProgress = 0.0
            }
            
            try? await Task.sleep(nanoseconds: 500_000_000)
            await requestRemoteDirectory(at: targetDirectory)
        } catch {
            await MainActor.run {
                AppState.shared.isDownloadingFile = false
                FileTransferQueueManager.shared.updateProgress(id: transferId, bytesTransferred: 0, status: "failed")
            }
            throw error
        }
    }
    
    private func sendChunkWithRetry(
        chunk: FileTransferChunkPayload,
        relativeName: String,
        targetDirectory: String,
        modDateMs: Int64,
        fileSha256: String,
        totalSize: Int64,
        activeDeviceId: String,
        connectionManager: ConnectionManager
    ) async throws -> Int {
        let maxRetries = ProtocolConstants.Transfer.maxRetries // 3
        var attempt = 0
        
        let payload: [String: Any] = [
            "action": "upload_chunk",
            "transferId": chunk.transferId,
            "chunkIndex": chunk.chunkIndex,
            "totalChunks": chunk.totalChunks,
            "offsetBytes": chunk.offsetBytes,
            "chunkDataBase64": chunk.chunkDataBase64,
            "checksumSha256": chunk.checksumSha256,
            "fileSha256": fileSha256,
            "totalSize": totalSize,
            "fileName": relativeName,
            "targetDirectory": targetDirectory,
            "modificationDateMs": modDateMs
        ]
        
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw NSError(domain: "FileTransfer", code: -4, userInfo: [NSLocalizedDescriptionKey: "Serialization failed"])
        }
        
        while attempt <= maxRetries {
            while true {
                let status = await MainActor.run {
                    FileTransferQueueManager.shared.activeTransfers.first(where: { $0.id == chunk.transferId })?.status
                }
                if status == "cancelled" {
                    throw NSError(domain: "FileTransfer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
                }
                if status == "paused" {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                break
            }
            
            let correlationId = UUID().uuidString
            let message = MessageRouter.createRequest(channel: "files", payload: payloadData, correlationId: correlationId)
            
            do {
                try await connectionManager.send(message, to: activeDeviceId)
                let timeout = ProtocolConstants.Transfer.chunkAckTimeoutSeconds
                let (status, details) = await ResponseAwaiter.shared.awaitResponse(correlationId: correlationId, timeoutSec: timeout)
                if status {
                    return chunk.chunkDataBase64.count
                } else {
                    LinkOSLogger.shared.warning("[FileTransfer] Retry \(attempt + 1)/\(maxRetries) for chunk \(chunk.chunkIndex) due to: \(details)", category: .files)
                }
            } catch {
                LinkOSLogger.shared.warning("[FileTransfer] Retry \(attempt + 1)/\(maxRetries) for chunk \(chunk.chunkIndex) due to error: \(error.localizedDescription)", category: .files)
            }
            
            attempt += 1
            if attempt <= maxRetries {
                try? await Task.sleep(nanoseconds: 200_000_000 * UInt64(attempt))
            }
        }
        
        throw NSError(domain: "FileTransfer", code: -5, userInfo: [NSLocalizedDescriptionKey: "Chunk \(chunk.chunkIndex) failed after \(maxRetries) retries"])
    }
    
    func downloadRemoteFileFromAndroid(remotePath: String, transferId: String? = nil, isDragOrPreview: Bool = false) async {
        guard let connectionManager = connectionManager,
              let activeDeviceId = await MainActor.run(body: { AppState.shared.activeConnectedDevice?.id }) else { return }
        
        var payload: [String: Any] = [
            "action": "download",
            "path": remotePath
        ]
        if let tid = transferId {
            payload["transferId"] = tid
        }
        
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let correlationId = UUID().uuidString
        let message = MessageRouter.createRequest(channel: "files", payload: payloadData, correlationId: correlationId)
        
        if !isDragOrPreview {
            await MainActor.run {
                AppState.shared.isDownloadingFile = true
                AppState.shared.fileDownloadProgress = 0.1
            }
        }
        
        try? await connectionManager.send(message, to: activeDeviceId)
    }
    
    func downloadFileToTemp(remotePath: String, fileName: String, isCopy: Bool = false, isDragOrPreview: Bool = false) async throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(fileName)
        return try await downloadFileToSpecificPath(remotePath: remotePath, toLocalURL: tempURL, isCopy: isCopy, isDragOrPreview: isDragOrPreview)
    }
    
    func downloadFileToSpecificPath(remotePath: String, toLocalURL: URL, isCopy: Bool = false, isDragOrPreview: Bool = false) async throws -> URL {
        let transferId = UUID().uuidString
        transferIsCopy[transferId] = isCopy
        transferIsDragOrPreview[transferId] = isDragOrPreview
        
        activeTransferPaths[transferId] = toLocalURL.path
        
        if isDragOrPreview {
            try? Data().write(to: toLocalURL)
        }
        
        do {
            let resultURL = try await withCheckedThrowingContinuation { continuation in
                downloadCompletionsLock.lock()
                downloadCompletions[transferId] = continuation
                downloadCompletionsLock.unlock()
                
                Task {
                    await downloadRemoteFileFromAndroid(remotePath: remotePath, transferId: transferId, isDragOrPreview: isDragOrPreview)
                }
            }
            if !isDragOrPreview {
                await MainActor.run {
                    AppState.shared.isDownloadingFile = false
                    AppState.shared.fileDownloadProgress = 0.0
                }
            }
            return resultURL
        } catch {
            if !isDragOrPreview {
                await MainActor.run {
                    AppState.shared.isDownloadingFile = false
                    AppState.shared.fileDownloadProgress = 0.0
                }
            }
            throw error
        }
    }
    
    func downloadFile(remotePath: String, toLocalURL: URL) async throws {
        let transferId = UUID().uuidString
        activeTransferPaths[transferId] = toLocalURL.path
        
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                downloadCompletionsLock.lock()
                downloadCompletions[transferId] = continuation
                downloadCompletionsLock.unlock()
                
                Task {
                    await downloadRemoteFileFromAndroid(remotePath: remotePath, transferId: transferId)
                }
            }
            await MainActor.run {
                AppState.shared.isDownloadingFile = false
                AppState.shared.fileDownloadProgress = 0.0
            }
        } catch {
            await MainActor.run {
                AppState.shared.isDownloadingFile = false
                AppState.shared.fileDownloadProgress = 0.0
            }
            throw error
        }
    }
    
    func commandPaletteActions() -> [CommandPaletteAction] {
        [
            CommandPaletteAction(
                id: "files.open_downloads",
                title: "Open Downloads Folder",
                subtitle: "Browse Mac Downloads directory",
                icon: "folder",
                keywords: ["files", "finder", "downloads"],
                category: "File Manager",
                action: {
                    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                    NSWorkspace.shared.open(downloads)
                }
            )
        ]
    }
}
