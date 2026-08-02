import Foundation

struct AISearchResultItem: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let path: String
    let domain: String
    let relevanceScore: Double
}

/// AI Text/Metadata Search Service.
/// Note: Explicitly excludes OCR, image embeddings, semantic photo search, or visual AI.
/// Those capabilities belong to OptixPhotos and will be integrated via AISearchExtension.
final class AISearchService {
    
    func searchMetadata(query: String, domain: String = "files", limit: Int = 20) -> [AISearchResultItem] {
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard let enumerator = fm.enumerator(at: home, includingPropertiesForKeys: [.nameKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        
        var results: [AISearchResultItem] = []
        for case let fileURL as URL in enumerator {
            if results.count >= limit { break }
            let name = fileURL.lastPathComponent
            if name.lowercased().contains(lower) {
                results.append(AISearchResultItem(
                    id: fileURL.path,
                    title: name,
                    subtitle: fileURL.path,
                    path: fileURL.path,
                    domain: "files",
                    relevanceScore: 0.9
                ))
            }
        }
        return results
    }
}

/// Extension interface for future shared AI Engine integration (e.g., OptixPhotos).
protocol AISearchExtension {
    var extensionId: String { get }
    var displayName: String { get }
    func queryExternalEngine(query: String) async -> [AISearchResultItem]
}
