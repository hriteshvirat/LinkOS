import Foundation
import AppKit
import QuickLookThumbnailing

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

final class FileSystemService {
    
    func listDirectory(at path: String, includeHidden: Bool = false) throws -> [FileItemInfo] {
        var sanitizedPath = path
        if sanitizedPath.isEmpty {
            sanitizedPath = "/Users"
        }
        if sanitizedPath != "/Users" && !sanitizedPath.hasPrefix("/Users/") {
            sanitizedPath = "/Users"
        }
        
        let url = URL(fileURLWithPath: sanitizedPath)
        let fm = FileManager.default
        
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey, .typeIdentifierKey]
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: resourceKeys, options: options)
        
        return contents.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)) else { return nil }
            let isDir = values.isDirectory ?? false
            let size = UInt64(values.fileSize ?? 0)
            let modDate = Int64((values.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000)
            
            let name = fileURL.lastPathComponent
            var isHidden = values.isHidden ?? false
            
            let lowerName = name.lowercased()
            let ext = fileURL.pathExtension.lowercased()
            if name.hasPrefix(".") || name.hasPrefix("~$") ||
               ext == "tmp" || ext == "temp" || ext == "lnk" || ext == "files" ||
               lowerName.contains("cache") || lowerName.contains("metadata") {
                isHidden = true
            }
            
            if isHidden && !includeHidden {
                return nil
            }
            
            return FileItemInfo(
                id: fileURL.path,
                name: name,
                path: fileURL.path,
                isDirectory: isDir,
                sizeBytes: size,
                modificationDateMs: modDate,
                mimeType: fileURL.pathExtension,
                permissions: "rwxr-xr-x",
                isHidden: isHidden
            )
        }
    }
    
    func performOperation(action: String, sourcePath: String, destinationPath: String? = nil) throws {
        let fm = FileManager.default
        let srcURL = URL(fileURLWithPath: sourcePath)
        
        switch action {
        case "copy":
            if let dest = destinationPath {
                try fm.copyItem(at: srcURL, to: URL(fileURLWithPath: dest))
            }
        case "move":
            if let dest = destinationPath {
                try fm.moveItem(at: srcURL, to: URL(fileURLWithPath: dest))
            }
        case "rename":
            if let dest = destinationPath {
                try fm.moveItem(at: srcURL, to: URL(fileURLWithPath: dest))
            }
        case "delete":
            try fm.removeItem(at: srcURL)
        case "trash":
            try fm.trashItem(at: srcURL, resultingItemURL: nil)
        default:
            break
        }
    }
    
    func generateThumbnail(for path: String, size: CGSize = CGSize(width: 128, height: 128)) async -> Data? {
        let url = URL(fileURLWithPath: path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2.0, representationTypes: [.thumbnail, .icon])
        
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let cgImage = representation?.cgImage {
                    let nsImage = NSImage(cgImage: cgImage, size: size)
                    if let tiff = nsImage.tiffRepresentation {
                        continuation.resume(returning: tiff)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
