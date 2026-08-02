import Foundation

struct AppVersionInfo: Codable {
    let version: String
    let buildNumber: Int
    let minSupportedProtocolVersion: Int
}

final class MigrationManager {
    private let currentSchemaVersion = 1
    
    func performMigrationsIfNeeded() {
        let lastVersion = UserDefaults.standard.integer(forKey: "linkos_schema_version")
        if lastVersion < currentSchemaVersion {
            LinkOSLogger.shared.info("Migrating database schema from v\(lastVersion) to v\(currentSchemaVersion)", category: .app)
            // Perform schema migration scripts here
            UserDefaults.standard.set(currentSchemaVersion, forKey: "linkos_schema_version")
        }
    }
}

final class UpdateManager {
    static let shared = UpdateManager()
    
    func checkProtocolCompatibility(remoteVersion: Int) -> Bool {
        let currentProtocolVersion = 1
        return remoteVersion >= currentProtocolVersion
    }
}
