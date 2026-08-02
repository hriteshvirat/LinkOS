import Foundation

struct GitRepoStatus: Codable {
    let repoName: String
    let branch: String
    let hasUncommittedChanges: Bool
    let aheadCount: Int
    let behindCount: Int
}

struct DockerContainerInfo: Codable, Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let isRunning: Bool
}

final class DevModePlugin: LinkOSPlugin {
    let pluginId = "devmode"
    let displayName = "Developer Dashboard"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["devmode"]
    let requiredPermissions: Set<String> = ["SYSTEM_INFO", "TERMINAL_ACCESS"]
    
    private(set) var isActive = false
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("DevModePlugin activated", category: .plugin)
    }
    
    func deactivate() async {
        isActive = false
        LinkOSLogger.shared.info("DevModePlugin deactivated", category: .plugin)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        let repo = GitRepoStatus(repoName: "LinkOS", branch: "main", hasUncommittedChanges: false, aheadCount: 0, behindCount: 0)
        let containers = [
            DockerContainerInfo(id: "c1", name: "redis-cache", image: "redis:latest", status: "Up 2 hours", isRunning: true),
            DockerContainerInfo(id: "c2", name: "postgres-db", image: "postgres:16", status: "Up 2 hours", isRunning: true)
        ]
        
        let payload: [String: Any] = [
            "git": try? JSONEncoder().encode(repo),
            "docker": try? JSONEncoder().encode(containers)
        ]
        
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            let response = MessageRouter.createResponse(channel: "devmode", payload: data, correlationId: message.correlationId)
            try? await connectionManager?.send(response, to: message.deviceId)
        }
    }
}
