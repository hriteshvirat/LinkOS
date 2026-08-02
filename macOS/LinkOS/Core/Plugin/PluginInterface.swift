import Foundation

// MARK: - Plugin Interface

/// Protocol that all LinkOS plugins must conform to.
/// Plugins are modular features that can be activated/deactivated independently.
protocol LinkOSPlugin: AnyObject {
    /// Unique identifier for this plugin
    var pluginId: String { get }
    
    /// Human-readable display name
    var displayName: String { get }
    
    /// Plugin version (semver)
    var version: String { get }
    
    /// Channels this plugin subscribes to (e.g., "clipboard", "input")
    var subscribedChannels: Set<String> { get }
    
    /// Permissions required by this plugin
    var requiredPermissions: Set<String> { get }
    
    /// Current activation state
    var isActive: Bool { get }
    
    /// Called when the plugin is activated. Set up resources here.
    func activate() async throws
    
    /// Called when the plugin is deactivated. Clean up resources here.
    func deactivate() async
    
    /// Handle an incoming message routed to one of the subscribed channels.
    func handleMessage(_ message: LinkOSMessageEnvelope) async
    
    /// Provide commands for the universal command palette.
    func commandPaletteActions() -> [CommandPaletteAction]
}

// Default implementations
extension LinkOSPlugin {
    var requiredPermissions: Set<String> { [] }
    func commandPaletteActions() -> [CommandPaletteAction] { [] }
}

// MARK: - Plugin Manager

/// Manages plugin lifecycle: registration, activation, deactivation, message routing.
actor PluginManager {
    private var registeredPlugins: [String: LinkOSPlugin] = [:]
    private var activePlugins: [String: LinkOSPlugin] = [:]
    private let logger = LinkOSLogger.shared
    
    /// Register a plugin. Does not activate it.
    func register(_ plugin: LinkOSPlugin) {
        registeredPlugins[plugin.pluginId] = plugin
        logger.info("Registered plugin: \(plugin.displayName) v\(plugin.version)", category: .plugin)
    }
    
    /// Activate a registered plugin.
    func activate(_ pluginId: String) async throws {
        guard let plugin = registeredPlugins[pluginId] else {
            throw PluginError.notFound(pluginId)
        }
        guard !plugin.isActive else { return }
        
        try await plugin.activate()
        activePlugins[pluginId] = plugin
        logger.info("Activated plugin: \(plugin.displayName)", category: .plugin)
    }
    
    /// Deactivate an active plugin.
    func deactivate(_ pluginId: String) async {
        guard let plugin = activePlugins.removeValue(forKey: pluginId) else { return }
        await plugin.deactivate()
        logger.info("Deactivated plugin: \(plugin.displayName)", category: .plugin)
    }
    
    /// Deactivate all plugins (shutdown).
    func deactivateAll() async {
        for (id, _) in activePlugins {
            await deactivate(id)
        }
    }
    
    /// Retrieve a registered plugin of a specific type.
    func getPlugin<T: LinkOSPlugin>(_ type: T.Type) -> T? {
        for plugin in registeredPlugins.values {
            if let typed = plugin as? T {
                return typed
            }
        }
        return nil
    }
    
    /// Route a message to all active plugins subscribed to its channel.
    func routeMessage(_ message: LinkOSMessageEnvelope) async {
        for (_, plugin) in activePlugins where plugin.subscribedChannels.contains(message.channel) {
            await plugin.handleMessage(message)
        }
    }
    
    /// Collect command palette actions from all active plugins.
    func allCommandPaletteActions() -> [CommandPaletteAction] {
        activePlugins.values.flatMap { $0.commandPaletteActions() }
    }
    
    /// Register all built-in plugins (called on startup).
    func registerBuiltInPlugins(connectionManager: ConnectionManager) async {
        let plugins: [LinkOSPlugin] = [
            await ClipboardPlugin(connectionManager: connectionManager),
            AudioPlugin(connectionManager: connectionManager),
            await StreamDeckPlugin(connectionManager: connectionManager),
            await NotificationsPlugin(connectionManager: connectionManager),
            AIAgentPlugin(connectionManager: connectionManager),
            FileSystemPlugin(connectionManager: connectionManager),
            PresencePlugin(),
            TerminalPlugin(connectionManager: connectionManager),
            DashboardPlugin(connectionManager: connectionManager),
            TabletPlugin(),
            RemoteDesktopPlugin(connectionManager: connectionManager),
            DevModePlugin(connectionManager: connectionManager),
            TrackpadPlugin(),
            await PhoneMirroringPlugin(connectionManager: connectionManager)
        ]
        
        for plugin in plugins {
            register(plugin)
            do {
                try await activate(plugin.pluginId)
            } catch {
                logger.error("Failed to activate built-in plugin \(plugin.pluginId): \(error)", category: .plugin)
            }
        }
        logger.info("Built-in plugin registration and activation complete", category: .plugin)
    }
}

// MARK: - Supporting Types

enum PluginError: LocalizedError {
    case notFound(String)
    case activationFailed(String, Error)
    case permissionDenied(String, String)
    
    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "Plugin not found: \(id)"
        case .activationFailed(let id, let error): return "Failed to activate \(id): \(error)"
        case .permissionDenied(let id, let perm): return "Plugin \(id) requires permission: \(perm)"
        }
    }
}

/// In-memory message envelope used internally (not the protobuf wire type).
struct LinkOSMessageEnvelope {
    let messageId: String
    let type: MessageEnvelopeType
    let channel: String
    let timestamp: Date
    let payload: Data
    let deviceId: String
    let correlationId: String?
    
    enum MessageEnvelopeType {
        case request, response, event, stream, ack, error
    }
}

/// Action exposed to the universal command palette by a plugin.
struct CommandPaletteAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String           // SF Symbol name
    let keywords: [String]     // Additional search terms
    let category: String       // Grouping category
    let action: () async -> Void
}
