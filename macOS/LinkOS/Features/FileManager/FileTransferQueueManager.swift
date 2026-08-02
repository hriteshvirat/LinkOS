import Foundation

public struct TransferItem: Codable, Identifiable {
    public let id: String
    public let fileName: String
    public let totalSize: Int64
    public var bytesTransferred: Int64
    public var status: String // "pending", "transferring", "paused", "completed", "failed", "cancelled"
    public var lastModified: Date
    public var isUpload: Bool

    enum CodingKeys: String, CodingKey {
        case id, fileName, totalSize, bytesTransferred, status, lastModified, isUpload
    }

    public init(id: String, fileName: String, totalSize: Int64, bytesTransferred: Int64, status: String, lastModified: Date, isUpload: Bool) {
        self.id = id
        self.fileName = fileName
        self.totalSize = totalSize
        self.bytesTransferred = bytesTransferred
        self.status = status
        self.lastModified = lastModified
        self.isUpload = isUpload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        totalSize = try container.decode(Int64.self, forKey: .totalSize)
        bytesTransferred = try container.decode(Int64.self, forKey: .bytesTransferred)
        status = try container.decode(String.self, forKey: .status)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
        isUpload = try container.decodeIfPresent(Bool.self, forKey: .isUpload) ?? false
    }
}

@MainActor
public final class FileTransferQueueManager: ObservableObject {
    public static let shared = FileTransferQueueManager()
    
    @Published public var activeTransfers: [TransferItem] = []
    
    private let queueFileUrl: URL
    
    private init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportDir = paths[0].appendingPathComponent("LinkOS")
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        self.queueFileUrl = appSupportDir.appendingPathComponent("transfer_queue.json")
        loadQueue()
    }
    
    public func addTransfer(id: String, fileName: String, totalSize: Int64, isUpload: Bool) {
        let item = TransferItem(
            id: id,
            fileName: fileName,
            totalSize: totalSize,
            bytesTransferred: 0,
            status: "pending",
            lastModified: Date(),
            isUpload: isUpload
        )
        activeTransfers.append(item)
        saveQueue()
    }
    
    public func updateProgress(id: String, bytesTransferred: Int64, status: String) {
        if let idx = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[idx].bytesTransferred = bytesTransferred
            activeTransfers[idx].status = status
            activeTransfers[idx].lastModified = Date()
            saveQueue()
        }
    }
    
    public func pauseTransfer(id: String) {
        if let idx = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[idx].status = "paused"
            saveQueue()
        }
    }
    
    public func resumeTransfer(id: String) {
        if let idx = activeTransfers.firstIndex(where: { $0.id == id }) {
            activeTransfers[idx].status = "transferring"
            saveQueue()
        }
    }
    
    public func cancelTransfer(id: String) {
        activeTransfers.removeAll(where: { $0.id == id })
        saveQueue()
    }
    
    public func clearHistory() {
        activeTransfers.removeAll(where: { $0.status == "completed" || $0.status == "failed" || $0.status == "cancelled" })
        saveQueue()
    }
    
    private func saveQueue() {
        if let data = try? JSONEncoder().encode(activeTransfers) {
            try? data.write(to: queueFileUrl)
        }
    }
    
    private func loadQueue() {
        if let data = try? Data(contentsOf: queueFileUrl),
           let list = try? JSONDecoder().decode([TransferItem].self, from: data) {
            // Restore only incomplete/completed items from last session
            self.activeTransfers = list
        }
    }
}
