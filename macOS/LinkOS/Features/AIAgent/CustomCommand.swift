import Foundation
import AppKit
import UniformTypeIdentifiers

/// Supported action types for custom AI commands.
enum CustomCommandActionType: String, Codable, CaseIterable, Identifiable {
    var id: String { rawValue }
    case openURL = "OPEN_URL"
    case launchApp = "LAUNCH_APP"
    case openFolder = "OPEN_FOLDER"
    case systemAction = "SYSTEM_ACTION"

    var displayName: String {
        switch self {
        case .openURL: return "Open URL"
        case .launchApp: return "Launch App"
        case .openFolder: return "Open Folder"
        case .systemAction: return "System Action"
        }
    }
}

/// A user-defined command that intercepts AI prompts matching `trigger` and executes the action.
struct CustomCommand: Codable, Identifiable, Hashable {
    var id: UUID
    var trigger: String        // e.g. "/google", "reddit"
    var name: String           // display name
    var actionType: String     // raw value of CustomCommandActionType
    var template: String       // URL/path template with {query}, {clipboard}, {selection} placeholders
    var appName: String?       // for LAUNCH_APP: which app to use as the browser/launcher
    var isEnabled: Bool        // when false, the command is skipped during AI processing

    init(id: UUID = UUID(), trigger: String, name: String, actionType: String,
         template: String, appName: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.name = name
        self.actionType = actionType
        self.template = template
        self.appName = appName
        self.isEnabled = isEnabled
    }
}

/// Persistence layer for custom commands with import/export support.
class CustomCommandStore: ObservableObject {
    static let shared = CustomCommandStore()
    private let key = "linkos_custom_commands"

    @Published var commands: [CustomCommand] = []

    init() {
        self.commands = loadCommands()
    }

    func loadCommands() -> [CustomCommand] {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([CustomCommand].self, from: data) {
            return list
        }
        // Default commands — NOTE: "/make" is intentionally NOT included.
        // The "/make" namespace is reserved for user-defined commands only.
        let defaults = [
            CustomCommand(trigger: "/google", name: "Google Search",
                          actionType: "OPEN_URL",
                          template: "https://www.google.com/search?q={query}")
        ]
        saveCommands(defaults)
        return defaults
    }

    func saveCommands(_ list: [CustomCommand]) {
        self.commands = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - Import / Export

    /// Export commands to a JSON file via NSSavePanel.
    /// The exported file is a versioned wrapper: {"schemaVersion": 1, "commands": [...]}
    /// All fields are preserved faithfully: order, isEnabled, actionType, template, appName, trigger, name.
    @MainActor
    func exportCommandsToFile() {
        let panel = NSSavePanel()
        panel.title = "Export Custom Commands"
        panel.nameFieldStringValue = "linkos-commands.linkos-commands"
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let wrapper: [String: Any] = [
            "schemaVersion": 1,
            "commands": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(commands))) as? [[String: Any]] ?? []
        ]
        if let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// Import commands from a JSON file via NSOpenPanel.
    /// Merges with deduplication by trigger (case-insensitive). Existing commands win on conflict.
    /// Preserves all fields: order (appended after existing), isEnabled, actionType, template, appName.
    @MainActor
    func importCommandsFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Custom Commands"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }

        let importedCommands: [CustomCommand]
        if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let commandsArray = wrapper["commands"],
           let commandsData = try? JSONSerialization.data(withJSONObject: commandsArray) {
            importedCommands = (try? JSONDecoder().decode([CustomCommand].self, from: commandsData)) ?? []
        } else {
            importedCommands = (try? JSONDecoder().decode([CustomCommand].self, from: data)) ?? []
        }

        var merged = commands
        let existingTriggers = Set(merged.map { $0.trigger.lowercased().trimmingCharacters(in: .whitespaces) })
        for cmd in importedCommands {
            let t = cmd.trigger.lowercased().trimmingCharacters(in: .whitespaces)
            if !existingTriggers.contains(t) {
                merged.append(cmd)
            }
        }
        saveCommands(merged)
    }
}
