import Foundation

struct FileItemInfo: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: UInt64
    let modificationDateMs: Int64
    let mimeType: String
    let permissions: String
    let isHidden: Bool
}

func listDirectory(at path: String, includeHidden: Bool = false) throws -> [FileItemInfo] {
    var sanitizedPath = path
    if sanitizedPath.isEmpty {
        sanitizedPath = "/Users"
    }
    let url = URL(fileURLWithPath: sanitizedPath)
    let fm = FileManager.default
    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
    let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: [])
    return contents.compactMap { fileURL in
        guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
        return FileItemInfo(
            id: fileURL.path,
            name: fileURL.lastPathComponent,
            path: fileURL.path,
            isDirectory: values.isDirectory ?? false,
            sizeBytes: UInt64(values.fileSize ?? 0),
            modificationDateMs: 0,
            mimeType: "",
            permissions: "rwxr-xr-x",
            isHidden: values.isHidden ?? false
        )
    }
}

do {
    let files = try listDirectory(at: "/Users/hritesh")
    let data = try JSONEncoder().encode(files)
    if let jsonStr = String(data: data, encoding: .utf8) {
        print(jsonStr)
    }
} catch {
    print("Error: \(error)")
}
