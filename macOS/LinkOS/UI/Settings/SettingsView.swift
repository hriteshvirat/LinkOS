import SwiftUI

/// Settings view for the macOS app — manages connections, permissions, trusted devices, appearance, and debug.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    var isStandalone = false
    
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            
            PermissionsSettingsView()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
            
            TrustedDevicesSettingsView()
                .tabItem { Label("Trusted Devices", systemImage: "shield.checkmark") }
            
            DeveloperSettingsView()
                .tabItem { Label("Developer", systemImage: "terminal") }
            
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: isStandalone ? 580 : nil, height: isStandalone ? 440 : nil)
    }
}

struct DeveloperSettingsView: View {
    @AppStorage("developerLogMode") private var logMode: String = "Features Only"
    
    var body: some View {
        Form {
            Section("Developer Logging Mode") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select Developer Log Verbosity")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Controls which events appear in the in-app debug console and system log output.")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    
                    Picker("", selection: $logMode) {
                        Text("○ Features Only (Default - High-Level Feature Events)").tag("Features Only")
                        Text("○ Full System (Verbose Packets, Transport & Dumps)").tag("Full System")
                    }
                    .pickerStyle(.radioGroup)
                    .padding(.top, 4)
                }
                .padding(.vertical, 6)
            }
            
            Section("Developer Diagnostics Tools") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Protocol Debug Console")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Inspect real-time input events, screen stream status, and permission updates.")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                    Button("Open Console...") {
                        openDebugConsoleWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsSettingsView: View {
    @ObservedObject var pm = PermissionManager.shared
    
    var body: some View {
        Form {
            Section("macOS System Permission Dashboard") {
                ForEach(SystemPermissionType.allCases) { perm in
                    HStack(spacing: 12) {
                        let status = pm.status(for: perm)
                        Image(systemName: perm.iconName)
                            .font(.title3)
                            .foregroundStyle(status == .authorized ? Color.green : (status == .grantedRestartRequired ? Color.yellow : Color.orange))
                            .frame(width: 24)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(perm.rawValue)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(status.rawValue)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(status == .authorized ? Color.green : (status == .grantedRestartRequired ? Color.yellow : Color.orange))
                            }
                            Text(perm.usageDescription)
                                .font(.system(size: 10))
                                .foregroundStyle(.gray)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            pm.refreshPermissionStates()
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("linkos_theme") private var theme = "system"
    @AppStorage("linkos_launch_at_login") private var launchAtLogin = true
    @AppStorage("linkos_show_in_dock") private var showInDock = false
    
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle("Show in Dock", isOn: $showInDock)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ConnectionSettingsView: View {
    @AppStorage("linkos_local_only") private var localOnly = true
    @AppStorage("linkos_max_bandwidth") private var maxBandwidth = 0
    @AppStorage("linkos_video_quality") private var videoQuality = "adaptive"
    @AppStorage("linkos_max_fps") private var maxFPS = 60
    
    var body: some View {
        Form {
            Section("Network Mode") {
                Toggle("Local network only (no cloud)", isOn: $localOnly)
            }
            
            Section("Performance") {
                Picker("Video Quality", selection: $videoQuality) {
                    Text("Low (720p)").tag("low")
                    Text("Medium (1080p)").tag("medium")
                    Text("High (Native)").tag("high")
                    Text("Ultra (Native+)").tag("ultra")
                    Text("Adaptive").tag("adaptive")
                }
                
                Stepper("Max FPS: \(maxFPS)", value: $maxFPS, in: 15...120, step: 15)
                
                Stepper("Bandwidth Limit: \(maxBandwidth == 0 ? "Unlimited" : "\(maxBandwidth) Mbps")",
                        value: $maxBandwidth, in: 0...100, step: 5)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct TrustedDevicesSettingsView: View {
    @ObservedObject var store = TrustedDeviceStore.shared
    
    var body: some View {
        Form {
            Section("Remembered Trusted Devices") {
                if store.trustedDevices.isEmpty {
                    Text("No trusted devices saved yet. Approve a connection request to pair a device.")
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(store.trustedDevices) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "iphone")
                                .font(.title2)
                                .foregroundColor(device.isBlocked ? .gray : .blue)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.headline)
                                Text("\(device.manufacturer) \(device.model) • Last connected \(device.lastConnected.formatted(.dateTime.day().month().hour().minute()))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if device.isBlocked {
                                Button("Unblock") {
                                    withAnimation(.spring()) {
                                        store.unblockDevice(deviceId: device.id)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            } else {
                                Button("Block") {
                                    withAnimation(.spring()) {
                                        store.blockDevice(deviceId: device.id)
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                            
                            Button("Revoke") {
                                withAnimation(.spring()) {
                                    store.revokeTrust(deviceId: device.id)
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AdvancedSettingsView: View {
    @AppStorage("linkos_developer_mode") private var devModeEnabled = false
    @AppStorage("linkos_debug_overlay") private var debugOverlay = false
    @AppStorage("linkos_structured_logging") private var structuredLogging = true
    
    var body: some View {
        Form {
            Section("Developer") {
                Toggle("Developer Mode", isOn: $devModeEnabled)
                Toggle("Show debug overlay", isOn: $debugOverlay)
                Toggle("Structured logging", isOn: $structuredLogging)
                
                Button("Export Logs") {
                    exportLogs()
                }
            }
            
            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Protocol", value: "v1")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    private func exportLogs() {
        guard let data = LinkOSLogger.shared.exportLogs() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "linkos-logs-\(ISO8601DateFormatter().string(from: Date())).json"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }
}

struct CustomCommandsSettingsView: View {
    @ObservedObject var store = CustomCommandStore.shared
    @State private var editingCommand: CustomCommand?
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool
    
    var filteredCommands: [CustomCommand] {
        if searchQuery.isEmpty { return store.commands }
        return store.commands.filter { cmd in
            cmd.name.localizedCaseInsensitiveContains(searchQuery) ||
            cmd.trigger.localizedCaseInsensitiveContains(searchQuery)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Custom Agent Commands")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                
                TextField("Search...", text: $searchQuery)
                    .focused($isSearchFocused)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 150)
                
                Button(action: {
                    store.importCommandsFromFile()
                }) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                
                Button(action: {
                    store.exportCommandsToFile()
                }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                
                Button(action: {
                    editingCommand = CustomCommand(trigger: "", name: "", actionType: CustomCommandActionType.openURL.rawValue, template: "")
                }) {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "6366F1"))
            }
            .padding()
            .background(Color.white.opacity(0.02))
            
            List {
                ForEach(filteredCommands) { cmd in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { cmd.isEnabled },
                            set: { newValue in
                                var list = store.commands
                                if let idx = list.firstIndex(where: { $0.id == cmd.id }) {
                                    list[idx].isEnabled = newValue
                                    store.saveCommands(list)
                                }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cmd.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(cmd.isEnabled ? .white : .gray)
                            Text("\(cmd.trigger) -> \(CustomCommandActionType(rawValue: cmd.actionType)?.displayName ?? cmd.actionType)")
                                .font(.system(size: 11))
                                .foregroundStyle(cmd.isEnabled ? .gray : Color.gray.opacity(0.5))
                            Text(cmd.template)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(cmd.isEnabled ? Color(hex: "6366F1") : Color.gray.opacity(0.5))
                                .lineLimit(1)
                        }
                        Spacer()
                        
                        Button("Duplicate") {
                            var newCmd = cmd
                            newCmd.id = UUID()
                            newCmd.name = "\(cmd.name) Copy"
                            newCmd.trigger = "\(cmd.trigger)_copy"
                            var list = store.commands
                            list.append(newCmd)
                            store.saveCommands(list)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.gray)
                        
                        Button("Edit") {
                            editingCommand = cmd
                        }
                        .buttonStyle(.bordered)
                        
                        Button("Delete") {
                            var list = store.commands
                            list.removeAll { $0.id == cmd.id }
                            store.saveCommands(list)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            DispatchQueue.main.async {
                isSearchFocused = false
            }
        }
        .sheet(item: $editingCommand) { cmd in
            CustomCommandEditSheet(command: cmd) { updated in
                if !updated.trigger.isEmpty && !updated.name.isEmpty {
                    var list = store.commands
                    if let idx = list.firstIndex(where: { $0.id == updated.id }) {
                        list[idx] = updated
                    } else {
                        list.append(updated)
                    }
                    store.saveCommands(list)
                }
                editingCommand = nil
            }
            onCancel: {
                editingCommand = nil
            }
        }
    }
}

struct CustomCommandEditSheet: View {
    @State var command: CustomCommand
    var onSave: (CustomCommand) -> Void
    var onCancel: () -> Void
    
    var isDuplicateTrigger: Bool {
        let currentTrigger = command.trigger.lowercased().trimmingCharacters(in: .whitespaces)
        if currentTrigger.isEmpty { return false }
        return CustomCommandStore.shared.commands.contains { existing in
            existing.id != command.id && existing.trigger.lowercased().trimmingCharacters(in: .whitespaces) == currentTrigger
        }
    }
    
    var canSave: Bool {
        !command.trigger.trimmingCharacters(in: .whitespaces).isEmpty &&
        !command.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isDuplicateTrigger
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Text(CustomCommandStore.shared.commands.contains(where: { $0.id == command.id }) ? "Edit Custom Command" : "Add Custom Command")
                .font(.headline)
                .foregroundStyle(.white)
                .padding()
            
            Form {
                Section("General") {
                    TextField("Friendly Name (e.g. Make Query)", text: $command.name)
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Trigger Shortcut (e.g. /make)", text: $command.trigger)
                        if isDuplicateTrigger {
                            Text("A command with this trigger already exists.")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    }
                }
                
                Section("Action") {
                    Picker("Action Type", selection: $command.actionType) {
                        ForEach(CustomCommandActionType.allCases) { type in
                            Text(type.displayName).tag(type.rawValue)
                        }
                    }
                    
                    if command.actionType == CustomCommandActionType.launchApp.rawValue {
                        TextField("App Name or Bundle ID", text: Binding(
                            get: { command.appName ?? "" },
                            set: { command.appName = $0 }
                        ))
                    }
                    
                    TextField("Argument Template", text: $command.template)
                }
                
                Section("Variables") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• {query} - The text following the trigger").foregroundStyle(.gray)
                        Text("• {clipboard} - Current clipboard contents").foregroundStyle(.gray)
                        Text("• {selection} - Currently selected text").foregroundStyle(.gray)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
                
                Section("Preview") {
                    let previewStr = command.template.replacingOccurrences(of: "{query}", with: "example")
                    Text(previewStr.isEmpty ? "..." : previewStr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(hex: "6366F1"))
                        .lineLimit(2)
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                
                Button("Save Command") {
                    if canSave {
                        onSave(command)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "6366F1"))
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
        .background(Color(hex: "0D0F13"))
    }
}
