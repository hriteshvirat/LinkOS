import SwiftUI
import ObjectiveC

private var commandPaletteDelegateKey: UInt8 = 0

@MainActor
final class CommandPaletteWindowDelegate: NSObject, NSWindowDelegate {
    private var isClosing = false
    
    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing else { return }
        if let window = notification.object as? NSWindow, window.isVisible {
            isClosing = true
            window.close()
        }
    }
}

/// LinkOS macOS Application Entry Point
/// Runs as a native macOS application with main dashboard window and menu bar quick controls.
@main
struct LinkOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared
    
    var body: some Scene {
        // Main Dashboard Window — opens automatically when launched from Finder/Dock/Launchpad
        WindowGroup("LinkOS Ecosystem", id: "dashboard") {
            MainDashboardView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 720)
        
        // Menu bar presence is handled natively in AppDelegate via NSStatusItem + NSPopover
        
        // Settings window
        Settings {
            SettingsView(isStandalone: true)
                .environmentObject(appState)
        }
        
        // Device Pairing Window
        Window("Device Pairing", id: "pairing") {
            PairingView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 600)
        .commands {
            #if DEBUG
            CommandMenu("Developer") {
                Button("Debug Console...") {
                    openDebugConsoleWindow()
                }
                .keyboardShortcut("d", modifiers: [.command, .control])
            }
            #endif
        }
    }
}

@MainActor
func openDebugConsoleWindow() {
    for window in NSApplication.shared.windows {
        if window.title == "LinkOS Developer Console" {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
    
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    window.title = "LinkOS Developer Console"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: DebugConsoleView())
    window.center()
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

/// Main Dashboard Container View displayed when app is launched
struct MainDashboardContainerView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("lastSelectedSidebarTab") private var selectedTab: String = "dashboard"
    @State private var showAdvancedInfo: Bool = false
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Section("Ecosystem") {
                    NavigationLink(value: "dashboard") {
                        Label("System Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    NavigationLink(value: "remote") {
                        Label("Remote Desktop", systemImage: "display")
                    }
                    NavigationLink(value: "clipboard") {
                        Label("Universal Clipboard", systemImage: "doc.on.clipboard")
                    }
                    NavigationLink(value: "files") {
                        Label("Finder & Files", systemImage: "folder")
                    }
                    NavigationLink(value: "terminal") {
                        Label("PTY Terminal", systemImage: "terminal")
                    }
                }
                
                Section("Intelligence & Power") {
                    NavigationLink(value: "ai") {
                        Label("AI Mac Agent", systemImage: "sparkles")
                    }
                    NavigationLink(value: "streamdeck") {
                        Label("Shortcuts", systemImage: "square.grid.3x3.topleft.filled")
                    }
                    NavigationLink(value: "workspace") {
                        Label("Smart Workspace", systemImage: "macwindow.on.rectangle")
                    }
                    NavigationLink(value: "tablet") {
                        Label("Tablet & Display", systemImage: "ipad.landscape")
                    }
                }
                
                Section("System") {
                    NavigationLink(value: "dev") {
                        Label("Developer Mode", systemImage: "curlybraces")
                    }
                    NavigationLink(value: "settings") {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("LinkOS")
        } detail: {
            ZStack {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()
                
                Group {
                    switch selectedTab {
                    case "dashboard":
                        DashboardDetailView(showAdvancedInfo: $showAdvancedInfo)
                    case "remote":
                        RemoteDesktopDetailView()
                    case "clipboard":
                        ClipboardDetailView()
                    case "files":
                        FileBrowserDetailView()
                    case "terminal":
                        TerminalDetailView()
                    case "ai":
                        AIAgentDetailView()
                    case "streamdeck":
                        StreamDeckDetailView()
                    case "workspace":
                        WorkspaceDetailView()
                    case "tablet":
                        TabletDetailView()
                    case "dev":
                        DevModeDetailView()
                    case "settings":
                        SettingsView()
                    default:
                        DashboardDetailView(showAdvancedInfo: $showAdvancedInfo)
                    }
                }
                .id(selectedTab)
                .transition(.opacity.combined(with: .scale(scale: 0.99)))
                .animation(.easeInOut(duration: 0.15), value: selectedTab)
            }
        }
        .sheet(item: $appState.pendingPairingRequest) { request in
            PairingApprovalDialogView(request: request) { allow, remember in
                appState.respondToPairing(allow: allow, remember: remember)
            }
        }
    }
}

// Extension to make PendingPairingRequest conform to Identifiable for .sheet
extension PendingPairingRequest {
    // Already conforms via `id: String`
}

// ==============================================================================
// macOS Navigation Detail Views
// ==============================================================================

struct DashboardDetailView: View {
    @EnvironmentObject var appState: AppState
    @Binding var showAdvancedInfo: Bool
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("System Dashboard")
                    .font(.title.bold())
                
                // Active Connected Devices Card
                GlassmorphicCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(appState.isConnected ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                    .frame(width: 52, height: 52)
                                Image(systemName: appState.isConnected ? "laptopcomputer.and.iphone" : "wifi.exclamationmark")
                                    .font(.system(size: 24))
                                    .foregroundColor(appState.isConnected ? .green : .orange)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(!appState.connectedDeviceName.isEmpty ? appState.connectedDeviceName : (appState.activeConnectedDevice?.name ?? "No Active Connected Device"))
                                    .font(.title3.bold())
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(appState.isConnected ? Color.green : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(appState.isConnected ? "🟢 Connected & E2E Encrypted" : "Searching for nearby devices…")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            
                            HStack(spacing: 8) {
                                #if DEBUG
                                Button(action: { openDebugConsoleWindow() }) {
                                    Label("Debug Console", systemImage: "ladybug.fill")
                                        .font(.callout.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                #endif
                                
                                if appState.isConnected {
                                    Button(action: { appState.disconnectActiveDevice() }) {
                                        Text("Disconnect")
                                            .font(.callout.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                } else {
                                    Button(action: { PairingWindowManager.shared.showPairingWindow() }) {
                                        Text("Pair Device…")
                                            .font(.callout.weight(.medium))
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        
                        Divider()
                        
                        // Collapsible Advanced Technical Info
                        DisclosureGroup(isExpanded: $showAdvancedInfo) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Device ID:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(appState.activeConnectedDevice?.id ?? "None")
                                        .font(.system(.body, design: .monospaced))
                                }
                                HStack {
                                    Text("Encryption Session:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("AES-256-GCM + ECDH (P-256)")
                                        .font(.system(.body, design: .monospaced))
                                }
                                HStack {
                                    Text("Bonjour Protocol:")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("_linkos._tcp.local")
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .font(.caption)
                            .padding(.top, 8)
                        } label: {
                            Text("Advanced Technical Information")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                }
                
                // Nearby Android Devices Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nearby Android Devices")
                        .font(.headline)
                    
                    if appState.discoveredAndroidDevices.isEmpty {
                        GlassmorphicCard {
                            Text("No nearby Android devices found. Searching automatically...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(16)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(appState.discoveredAndroidDevices) { device in
                                GlassmorphicCard {
                                    HStack(spacing: 16) {
                                        Image(systemName: "smartphone")
                                            .font(.title2)
                                            .foregroundColor(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .font(.headline)
                                            Text("\(device.model) • \(device.host)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Text("Available")
                                            .font(.caption.bold())
                                            .foregroundColor(.green)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.green.opacity(0.15))
                                            .clipShape(Capsule())
                                        
                                        Button("Pair") {
                                            PairingWindowManager.shared.showPairingWindow()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }
                                    .padding(12)
                                }
                            }
                        }
                    }
                }
                
                // Trusted Devices Section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Trusted Devices")
                        .font(.headline)
                    
                    let trusted = TrustedDeviceStore.shared.trustedDevices
                    if trusted.isEmpty {
                        GlassmorphicCard {
                            Text("No trusted devices saved yet. Pair a device above to establish trust.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(16)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(trusted) { device in
                                GlassmorphicCard {
                                    HStack(spacing: 16) {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.title2)
                                            .foregroundColor(.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .font(.headline)
                                            Text("\(device.model) • Trusted")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Button("Forget") {
                                            TrustedDeviceStore.shared.revokeTrust(deviceId: device.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(.red)
                                    }
                                    .padding(12)
                                }
                            }
                        }
                    }
                }
                
                // Real-Time System Metrics Grid
                Text("Live System Metrics")
                    .font(.headline)
                    .foregroundStyle(.white)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // Local Mac Card
                    GlassmorphicCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("💻 Local macOS System")
                                .font(.headline)
                                .foregroundStyle(Color(hex: "6366F1"))
                            Divider().opacity(0.1)
                            Group {
                                HStack {
                                    Text("CPU Cores:")
                                    Spacer()
                                    Text("\(ProcessInfo.processInfo.activeProcessorCount) Cores").bold()
                                }
                                HStack {
                                    Text("Physical RAM:")
                                    Spacer()
                                    Text("\(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 1024) GB").bold()
                                }
                                HStack {
                                    Text("System OS:")
                                    Spacer()
                                    Text("macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)").bold()
                                }
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                        }
                        .padding()
                    }
                    
                    // Remote Android Card
                    GlassmorphicCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("📱 Remote Android Companion")
                                .font(.headline)
                                .foregroundStyle(appState.isConnected ? Color(hex: "10B981") : .gray)
                            Divider().opacity(0.1)
                            if appState.isConnected {
                                Group {
                                    HStack {
                                        Text("CPU Usage:")
                                        Spacer()
                                        Text(String(format: "%.1f%%", appState.remoteCpuUsage)).bold()
                                    }
                                    HStack {
                                        Text("RAM Usage:")
                                        Spacer()
                                        Text(String(format: "%.1f%%", appState.remoteRamUsage)).bold()
                                    }
                                    HStack {
                                        Text("Storage Usage:")
                                        Spacer()
                                        Text(String(format: "%.1f%%", appState.remoteDiskUsage)).bold()
                                    }
                                    HStack {
                                        Text("Wi-Fi Strength (RSSI):")
                                        Spacer()
                                        Text("\(appState.remoteWifiStrength) dBm").bold()
                                    }
                                    HStack {
                                        Text("Network Latency (RTT):")
                                        Spacer()
                                        Text(String(format: "%.1f ms", appState.remotePingRtt)).bold()
                                    }
                                    HStack {
                                        Text("Battery:")
                                        Spacer()
                                        Text("\(appState.androidBatteryPercent ?? 0)% \(appState.isAndroidCharging == true ? "⚡️ (\(appState.androidPowerSource ?? "AC"))" : "")").bold()
                                    }
                                }
                                .font(.system(size: 12))
                                .foregroundStyle(.gray)
                            } else {
                                Text("No Android device connected. Telemetry unavailable.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.gray)
                                    .padding(.vertical, 20)
                            }
                        }
                        .padding()
                    }
                }
            }
            .padding(24)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        GlassmorphicCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                    Spacer()
                }
                Text(value)
                    .font(.title2.bold())
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }
}

struct RemoteDesktopDetailView: View {
    @EnvironmentObject var appState: AppState
    @State private var isStreaming = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Remote Desktop & Mirroring")
                    .font(.title.bold())
                Spacer()
                if !appState.isConnected {
                    Label("Locked — Connect Device First", systemImage: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.orange)
                }
            }
            GlassmorphicCard {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.85))
                        .frame(height: 400)
                    if appState.isConnected {
                        VStack(spacing: 12) {
                            Image(systemName: "display")
                                .font(.system(size: 48))
                                .foregroundColor(.blue)
                            Text("Screen Capture Engine (ScreenCaptureKit 60FPS)")
                                .font(.headline)
                            Text("Hardware H.265 / WebRTC Stream Active")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "lock.circle.fill")
                                .font(.system(size: 52))
                                .foregroundColor(.gray)
                            Text("Remote Desktop Locked")
                                .font(.headline)
                            Text("Pair and connect an Android companion device to unlock 60FPS screen stream.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
            Spacer()
        }
        .padding(24)
    }
}

struct ClipboardDetailView: View {
    @EnvironmentObject var appState: AppState
    @State private var search = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Universal Clipboard History")
                .font(.title.bold())
            TextField("Search clipboard items...", text: $search)
                .textFieldStyle(.roundedBorder)
            if appState.isConnected {
                List {
                    HStack {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading) {
                            Text("https://github.com/linkos/core")
                                .font(.body.bold())
                            Text("Synced from \(!appState.connectedDeviceName.isEmpty ? appState.connectedDeviceName : (appState.activeConnectedDevice?.name ?? "Android")) • Just now")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Copy") {}.buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "lock.doc.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.gray)
                    Text("Universal Clipboard Locked")
                        .font(.headline)
                    Text("Connect your phone to sync clipboards instantly.")
                        .font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
    }
}

struct FileBrowserDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Finder Directory Browser & Transfer")
                .font(.title.bold())
            GlassmorphicCard {
                HStack(spacing: 16) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading) {
                        Text("Shared Finder Drive")
                            .font(.headline)
                        Text("256KB Resumable Chunked Transfer with SHA-256 Checksums")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Browse Files") {}.buttonStyle(.borderedProminent)
                }
                .padding()
            }
            Spacer()
        }
        .padding(24)
    }
}

struct TerminalDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Interactive PTY Terminal")
                .font(.title.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black)
                    .frame(height: 380)
                VStack(alignment: .leading, spacing: 8) {
                    Text("linkos@macbook-pro ~ % forkpty active (session #1)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                    Text("Connected via E2E Secure WebSocket PTY stream.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .padding()
            }
            Spacer()
        }
        .padding(24)
    }
}

struct AIAgentDetailView: View {
    @State private var prompt = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Mac Agent & Spotlight Search")
                .font(.title.bold())
            HStack {
                TextField("Ask AI Mac Agent to execute commands...", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                Button("Execute") {}
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct StreamDeckDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shortcuts Macro Grid")
                .font(.title.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(1...9, id: \.self) { idx in
                    GlassmorphicCard {
                        VStack(spacing: 8) {
                            Image(systemName: "square.grid.3x3.topleft.filled")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text("Macro Tile #\(idx)")
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .padding()
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

struct WorkspaceDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Smart Workspace Profiles")
                .font(.title.bold())
            HStack(spacing: 16) {
                WorkspaceTile(title: "Developer Profile", icon: "hammer.fill", color: .purple)
                WorkspaceTile(title: "Design Studio", icon: "paintpalette.fill", color: .pink)
                WorkspaceTile(title: "Focus & Chill", icon: "moon.fill", color: .blue)
            }
            Spacer()
        }
        .padding(24)
    }
}

struct WorkspaceTile: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        GlassmorphicCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(color)
                Text(title)
                    .font(.headline)
                Button("Launch Profile") {}
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

struct TabletDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tablet Wireless Display & Drawing Canvas")
                .font(.title.bold())
            GlassmorphicCard {
                VStack(spacing: 12) {
                    Image(systemName: "ipad.landscape")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                    Text("Apple Pencil & Stylus Pressure Engine")
                        .font(.headline)
                    Text("Low latency wireless display mirror active")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding()
            }
            Spacer()
        }
        .padding(24)
    }
}

struct DevModeDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Developer Mode Dashboard")
                .font(.title.bold())
            HStack(spacing: 16) {
                GlassmorphicCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Git Repository").font(.headline)
                        Text("Branch: main (clean)").font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                }
                GlassmorphicCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Docker Engine").font(.headline)
                        Text("3 Containers Running").font(.caption).foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

class WindowOpener {
    @MainActor static var openWindow: ((String) -> Void)? = nil
}

@MainActor
func focusOrOpenDashboard(tab: String? = nil) {
    var foundWindow: NSWindow? = nil
    for window in NSApplication.shared.windows {
        let title = window.title
        if (title.contains("Ecosystem") || title.contains("LinkOS")) &&
           !title.contains("Console") &&
           !title.contains("Pairing") &&
           !title.contains("Palette") {
            foundWindow = window
            break
        }
    }
    
    if let window = foundWindow {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let tab = tab {
            AppState.shared.selectedSidebarItem = tab
        }
    } else {
        if let open = WindowOpener.openWindow {
            open("dashboard")
        }
        NSApp.activate(ignoringOtherApps: true)
        if let tab = tab {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AppState.shared.selectedSidebarItem = tab
            }
        }
    }
}

@MainActor
func showCommandPalette() {
    // Check if already open. If so, close it!
    for window in NSApplication.shared.windows {
        if window.title == "LinkOS Command Palette" {
            window.close()
            return
        }
    }
    
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.title = "LinkOS Command Palette"
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: CommandPaletteView())
    window.isMovableByWindowBackground = true
    window.titlebarAppearsTransparent = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.center()
    window.level = .statusBar
    window.makeKeyAndOrderFront(nil)
    
    let delegate = CommandPaletteWindowDelegate()
    objc_setAssociatedObject(window, &commandPaletteDelegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.delegate = delegate
    
    NSApp.activate(ignoringOtherApps: true)
    window.makeKey()
}

@MainActor
func dismissCommandPalette() {
    for window in NSApplication.shared.windows {
        if window.title == "LinkOS Command Palette" {
            window.close()
            return
        }
    }
}
