import Foundation
import Combine

struct StreamDeckButtonConfig: Codable, Identifiable, Equatable {
    var id: String
    var position: Int
    var label: String
    var iconName: String
    /// Specifies how `iconName` should be interpreted on Android.
    /// - "sfSymbol": standard SF Symbol name (default; backward compatible with older versions)
    /// - "emoji": single Unicode emoji character
    /// - "material": Android Material icon name
    var iconType: String = "sfSymbol"
    var backgroundColorHex: String
    var actionType: String
    var actionPayload: [String: String]
    var isToggle: Bool = false
    var toggleState: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, position, label, iconName, iconType, backgroundColorHex, actionType, actionPayload, isToggle, toggleState
    }

    init(id: String, position: Int, label: String, iconName: String, iconType: String = "sfSymbol",
         backgroundColorHex: String, actionType: String, actionPayload: [String: String],
         isToggle: Bool = false, toggleState: Bool = false) {
        self.id = id
        self.position = position
        self.label = label
        self.iconName = iconName
        self.iconType = iconType
        self.backgroundColorHex = backgroundColorHex
        self.actionType = actionType
        self.actionPayload = actionPayload
        self.isToggle = isToggle
        self.toggleState = toggleState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        position = try container.decode(Int.self, forKey: .position)
        label = try container.decode(String.self, forKey: .label)
        iconName = try container.decode(String.self, forKey: .iconName)
        iconType = try container.decodeIfPresent(String.self, forKey: .iconType) ?? "sfSymbol"
        backgroundColorHex = try container.decode(String.self, forKey: .backgroundColorHex)
        actionType = try container.decode(String.self, forKey: .actionType)
        actionPayload = try container.decode([String: String].self, forKey: .actionPayload)
        isToggle = try container.decodeIfPresent(Bool.self, forKey: .isToggle) ?? false
        toggleState = try container.decodeIfPresent(Bool.self, forKey: .toggleState) ?? false
    }
}

struct StreamDeckPageConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var columns: Int
    var rows: Int
    var buttons: [StreamDeckButtonConfig]
}

@MainActor
final class StreamDeckService: ObservableObject {
    public static let shared = StreamDeckService()
    
    @Published var currentGrid: StreamDeckPageConfig
    
    private init() {
        if let data = UserDefaults.standard.data(forKey: "linkos_streamdeck_grid"),
           let decoded = try? JSONDecoder().decode(StreamDeckPageConfig.self, from: data) {
            self.currentGrid = decoded
        } else {
            self.currentGrid = StreamDeckPageConfig(
                id: "root",
                name: "Main Grid",
                columns: 3,
                rows: 3,
                buttons: [
                    StreamDeckButtonConfig(id: "b1", position: 0, label: "Mute Volume", iconName: "speaker.slash.fill", backgroundColorHex: "#EF4444", actionType: "SYSTEM_CONTROL", actionPayload: ["setting": "mute"]),
                    StreamDeckButtonConfig(id: "b2", position: 1, label: "Screenshot", iconName: "camera.fill", backgroundColorHex: "#3B82F6", actionType: "TAKE_SCREENSHOT", actionPayload: [:]),
                    StreamDeckButtonConfig(id: "b3", position: 2, label: "Open Chrome", iconName: "globe", backgroundColorHex: "#8B5CF6", actionType: "LAUNCH_APP", actionPayload: ["app_name": "Google Chrome"]),
                    StreamDeckButtonConfig(id: "b4", position: 3, label: "Downloads", iconName: "folder.fill", backgroundColorHex: "#10B981", actionType: "OPEN_FOLDER", actionPayload: ["path": "~/Downloads"]),
                    StreamDeckButtonConfig(id: "b5", position: 4, label: "Terminal", iconName: "terminal.fill", backgroundColorHex: "#F59E0B", actionType: "LAUNCH_APP", actionPayload: ["app_name": "Terminal"]),
                    StreamDeckButtonConfig(id: "b6", position: 5, label: "Lock Mac", iconName: "lock.fill", backgroundColorHex: "#6B7280", actionType: "SYSTEM_CONTROL", actionPayload: ["setting": "lock"]),
                    StreamDeckButtonConfig(id: "b7", position: 6, label: "Play/Pause", iconName: "playpause.fill", backgroundColorHex: "#EC4899", actionType: "SYSTEM_CONTROL", actionPayload: ["setting": "playpause"]),
                    StreamDeckButtonConfig(id: "b8", position: 7, label: "Empty Macro", iconName: "plus.circle", backgroundColorHex: "#4B5563", actionType: "NONE", actionPayload: [:]),
                    StreamDeckButtonConfig(id: "b9", position: 8, label: "Empty Macro", iconName: "plus.circle", backgroundColorHex: "#4B5563", actionType: "NONE", actionPayload: [:])
                ]
            )
        }
    }
    
    func saveGrid() {
        if let data = try? JSONEncoder().encode(currentGrid) {
            UserDefaults.standard.set(data, forKey: "linkos_streamdeck_grid")
            // Broadcast updated grid layout configuration to remote Android companion
            Task {
                await broadcastGridToAndroid()
            }
        }
    }
    
    func broadcastGridToAndroid() async {
        guard let data = try? JSONEncoder().encode(currentGrid) else { return }
        let payload = MessageRouter.createEvent(channel: "streamdeck", payload: data)
        await AppState.shared.connectionManager?.broadcast(payload)
    }
}

final class StreamDeckPlugin: LinkOSPlugin, ConnectionStateSubscriber {
    let subscriberId = "streamdeck_plugin"
    let pluginId = "streamdeck"
    let displayName = "Shortcuts"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["streamdeck"]
    let requiredPermissions: Set<String> = ["APP_LAUNCH", "SYSTEM_CONTROL", "KEYBOARD_INPUT"]
    
    private(set) var isActive = false
    private let executor = CommandExecutor()
    private weak var connectionManager: ConnectionManager?
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
    }
    
    func activate() async throws {
        isActive = true
        LinkOSLogger.shared.info("ShortcutsPlugin activated", category: .plugin)
        await ConnectionStateManager.shared.subscribe(self)
    }
    
    func deactivate() async {
        isActive = false
        LinkOSLogger.shared.info("ShortcutsPlugin deactivated", category: .plugin)
        await ConnectionStateManager.shared.unsubscribe(self.subscriberId)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        guard let json = try? JSONSerialization.jsonObject(with: message.payload) as? [String: Any],
              let actionType = json["action_type"] as? String else { return }
        
        var params: [String: String] = [:]
        if let paramsDict = json["params"] as? [String: Any] {
            for (k, v) in paramsDict {
                if let strVal = v as? String {
                    params[k] = strVal
                }
            }
        }
        
        let payload = AIActionPayload(actionType: actionType, parameters: params)
        let (status, details) = await executor.execute(action: payload)
        
        // Report success/failure back to the Android client
        let respPayload: [String: Any] = [
            "status": status ? "success" : "error",
            "message": details,
            "action_type": actionType
        ]
        
        if let respData = try? JSONSerialization.data(withJSONObject: respPayload, options: []),
           let connectionManager = connectionManager {
            let response = MessageRouter.createResponse(channel: "streamdeck", payload: respData, correlationId: message.correlationId)
            try? await connectionManager.send(response, to: message.deviceId)
        }
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        if phase == .connected {
            // Handshake safety delay
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await StreamDeckService.shared.broadcastGridToAndroid()
        }
    }
    
    func commandPaletteActions() -> [CommandPaletteAction] {
        [
            CommandPaletteAction(
                id: "streamdeck.open",
                title: "Shortcuts Actions",
                subtitle: "Trigger custom macros and shortcuts",
                icon: "square.grid.3x3",
                keywords: ["shortcuts", "macro", "button"],
                category: "Shortcuts",
                action: {
                    LinkOSLogger.shared.info("Shortcuts action palette opened", category: .plugin)
                }
            )
        ]
    }
}
