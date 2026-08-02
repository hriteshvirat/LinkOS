import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import Network

// MARK: - Color Hex Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 1, 1, 1)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
    
    func toHex() -> String? {
        let nsColor = NSColor(self)
        guard let rgbColor = nsColor.usingColorSpace(.deviceRGB) else { return nil }
        let r = Int(max(0.0, min(1.0, rgbColor.redComponent)) * 255.0)
        let g = Int(max(0.0, min(1.0, rgbColor.greenComponent)) * 255.0)
        let b = Int(max(0.0, min(1.0, rgbColor.blueComponent)) * 255.0)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

/// Main macOS App Window View — designed strictly following the LinkOS design blueprint.
/// Features grouped sidebar, connected device hero card with battery metrics, and dynamic detail panes.
struct MainDashboardView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var permissionManager = PermissionManager.shared
    @ObservedObject var streamDeckService = StreamDeckService.shared
    @ObservedObject var connectionState = ConnectionStateManager.shared
    @AppStorage("linkos_debug_overlay") private var debugOverlay = false
    @State private var showDiagnostics = false
    
    private var selectedSidebarItem: String {
        get { appState.selectedSidebarItem }
        nonmutating set { appState.selectedSidebarItem = newValue }
    }
    
    @State private var streamDeckSearchQuery = ""
    @State private var editingButton: StreamDeckButtonConfig? = nil
    @State private var aiPrompt = ""
    @State private var aiResponseLog: [String] = ["System ready. Ask me to: 'screenshot', 'open Terminal', 'mute', or 'open Safari'."]
    @State private var isExecutingAI = false
    
    @State private var localTerminalOutput = "LinkOS Local PTY Terminal v1.0\nReady.\n"
    @State private var localTerminalInput = ""
    @State private var localSession: TerminalSession? = nil
    
    @State private var showEditProfileSheet = false
    @State private var showAISettingsPopover = false
    @AppStorage("linkos_sidebar_width") private var sidebarWidth: Double = 220
    @State private var showAIProviderSheet = false
    @State private var showCustomCommandsSheet = false
    @State private var selectedModel: AIEngine.AIModelType = AIEngine.shared.modelType
    @State private var hasConnectedThisSession = false
    @State private var isReconnecting = false
    @State private var reconnectFailed = false
    
    // Camera Continuity States
    @State private var cameraFrame: NSImage? = nil
    @State private var isCameraFlashActive = false
    @State private var cameraZoomRatio: Float = 1.0
    @State private var selectedResolution = "720p"
    @State private var isRecordingVideo = false
    
    var body: some View {
        Group {
            if !appState.hasCompletedOnboarding {
                OnboardingView()
                    .environmentObject(appState)
                    .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    // Left Sidebar
                    sidebarView
                        .frame(width: CGFloat(sidebarWidth))
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 8)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering { NSCursor.resizeLeftRight.push() }
                                    else { NSCursor.pop() }
                                }
                                .gesture(
                                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { value in
                                            let newWidth = value.location.x
                                            sidebarWidth = Double(min(max(newWidth, 180), 320))
                                        }
                                )
                        }
                        .background(Color(hex: "0D0F13"))
                    
                    Divider()
                        .opacity(0.15)
                    
                    // Main Content Area
                    VStack(spacing: 0) {
                        // Top Header Bar
                        headerBar
                        
                        connectionBanner
                        
                        Divider()
                            .opacity(0.15)
                        
                        // Dynamic Detail Panes
                        ZStack(alignment: .bottomTrailing) {
                            Color(hex: "0B0C10").ignoresSafeArea()
                            
                            switch selectedSidebarItem {
                            case "Dashboard":
                                dashboardPane
                            case "Devices":
                                devicesPane
                            case "Phone":
                                phonePane
                            case "Remote Desktop":
                                remoteDesktopPane
                            case "Trackpad & Keyboard":
                                TrackpadSettingsPane()
                            case "Camera Continuity":
                                cameraContinuityPane
                            case "File Explorer":
                                filesPane
                            case "Downloads":
                                DownloadsView()
                            case "Clipboard":
                                clipboardPane
                            case "Terminal":
                                terminalPane
                            case "AI Agent":
                                aiAgentPane
                            case "Shortcuts":
                                streamDeckPane
                            case "Settings":
                                SettingsView()
                                    .padding(20)
                            default:
                                dashboardPane
                            }
                            
                            if debugOverlay || appState.showDebugOverlay {
                                debugHUDView
                            }
                        }
                    }
                    .background(Color(hex: "0B0C10"))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(isPresented: $showEditProfileSheet) {
            EditProfileView(isPresented: $showEditProfileSheet)
                .environmentObject(appState)
        }
        .onAppear {
            CameraReceiverService.shared.onFrameReceived = { img, flashActive, lens in
                self.cameraFrame = img
                self.isCameraFlashActive = flashActive
                if self.selectedSidebarItem != "Camera Continuity" {
                    self.selectedSidebarItem = "Camera Continuity"
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CameraContinuityCaptureRequested"))) { _ in
            self.captureCurrentCameraFrame()
        }
        .onChange(of: appState.isConnected) { _, connected in
            if connected {
                hasConnectedThisSession = true
                isReconnecting = false
                reconnectFailed = false
            }
        }
    }
    
    // MARK: - Sidebar View
    
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Brand Logo
            HStack(spacing: 10) {
                if let logoUrl = Bundle.module.url(forResource: "linkos_logo", withExtension: "png"),
                   let nsImg = NSImage(contentsOf: logoUrl) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let logoImage = NSImage(named: "linkos_logo") {
                    Image(nsImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "3B82F6")], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 34, height: 34)
                        
                        Image(systemName: "infinity")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("LinkOS")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                    Text("One Connection. Everything.")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            // Sidebar Items Grouped (Hides unfinished features: Smart Workspace, Tablet Display)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarSection(title: nil) {
                        SidebarRow(title: "Dashboard", icon: "square.grid.2x2", isSelected: selectedSidebarItem == "Dashboard") {
                            selectedSidebarItem = "Dashboard"
                        }
                    }
                    
                    SidebarSection(title: "WORKSPACE") {
                        SidebarRow(title: "Devices", icon: "laptopcomputer.and.iphone", isSelected: selectedSidebarItem == "Devices") {
                            selectedSidebarItem = "Devices"
                        }
                        SidebarRow(title: "Phone", icon: "iphone", isSelected: selectedSidebarItem == "Phone") {
                            selectedSidebarItem = "Phone"
                        }
                        SidebarRow(title: "Remote Desktop", icon: "desktopcomputer", isSelected: selectedSidebarItem == "Remote Desktop") {
                            selectedSidebarItem = "Remote Desktop"
                        }
                        SidebarRow(title: "Trackpad & Keyboard", icon: "hand.tap", isSelected: selectedSidebarItem == "Trackpad & Keyboard") {
                            selectedSidebarItem = "Trackpad & Keyboard"
                        }
                        SidebarRow(title: "Camera Continuity", icon: "camera", isSelected: selectedSidebarItem == "Camera Continuity") {
                            selectedSidebarItem = "Camera Continuity"
                        }
                        SidebarRow(title: "File Explorer", icon: "folder", isSelected: selectedSidebarItem == "File Explorer") {
                            selectedSidebarItem = "File Explorer"
                        }
                        SidebarRow(title: "Downloads", icon: "arrow.down.circle", isSelected: selectedSidebarItem == "Downloads") {
                            selectedSidebarItem = "Downloads"
                        }
                        SidebarRow(title: "Clipboard", icon: "doc.on.clipboard", isSelected: selectedSidebarItem == "Clipboard") {
                            selectedSidebarItem = "Clipboard"
                        }
                        SidebarRow(title: "Terminal", icon: "terminal", isSelected: selectedSidebarItem == "Terminal") {
                            selectedSidebarItem = "Terminal"
                        }
                        SidebarRow(title: "AI Agent", icon: "brain", isSelected: selectedSidebarItem == "AI Agent") {
                            selectedSidebarItem = "AI Agent"
                        }
                        SidebarRow(title: "Shortcuts", icon: "square.grid.3x3", isSelected: selectedSidebarItem == "Shortcuts") {
                            selectedSidebarItem = "Shortcuts"
                        }
                    }
                    
                    SidebarSection(title: "SYSTEM") {
                        SidebarRow(title: "Settings", icon: "gearshape", isSelected: selectedSidebarItem == "Settings") {
                            selectedSidebarItem = "Settings"
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            
            Spacer()
        }
    }
    
    private var connectionBanner: some View {
        Group {
            if !appState.isConnected {
                if hasConnectedThisSession {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(hex: "F59E0B"))
                            .font(.system(size: 12))
                        Text(isReconnecting ? "Reconnecting..." : (reconnectFailed ? "Reconnection Failed" : "Not Connected"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        
                        if isReconnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        
                        Spacer()
                        
                        if !isReconnecting {
                            if reconnectFailed {
                                Button("Pair Devices") {
                                    selectedSidebarItem = "Devices"
                                    reconnectFailed = false
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(hex: "3B82F6").opacity(0.15))
                                .foregroundStyle(Color(hex: "3B82F6"))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Button("Reconnect") {
                                    isReconnecting = true
                                    reconnectFailed = false
                                    reconnectToPreviousDevice()
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                        if !appState.isConnected {
                                            isReconnecting = false
                                            reconnectFailed = true
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color(hex: "F59E0B").opacity(0.15))
                                .foregroundStyle(Color(hex: "F59E0B"))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color(hex: "F59E0B").opacity(0.06))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.gray).font(.system(size: 12))
                        Text("Not Connected")
                            .font(.system(size: 11)).foregroundStyle(.gray)
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Color.white.opacity(0.02))
                }
            }
        }
    }
    
    private func reconnectToPreviousDevice() {
        guard let lastTrusted = TrustedDeviceStore.shared.trustedDevices
            .sorted(by: { $0.lastConnected > $1.lastConnected })
            .first else {
            isReconnecting = false
            reconnectFailed = true
            return
        }
        
        guard let discovered = appState.discoveredAndroidDevices.first(where: { $0.id == lastTrusted.id }) else {
            isReconnecting = false
            reconnectFailed = true
            return
        }
        
        let localIP = appState.getLocalIPAddress()
        let invitePayload = "{\"action\":\"CONNECT_TO\",\"host\":\"\(localIP)\",\"port\":52637,\"mode\":\"TRUSTED\"}\n"
        
        let connection = NWConnection(
            host: NWEndpoint.Host(discovered.host),
            port: NWEndpoint.Port(rawValue: 52638)!,
            using: .tcp
        )
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let data = invitePayload.data(using: .utf8)!
                connection.send(content: data, completion: .contentProcessed({ error in
                    connection.cancel()
                }))
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global())
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedSidebarItem)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Text(appState.isConnected ? "🟢 System Connected & Secure" : "Overview of your connected ecosystem")
                    .font(.system(size: 11))
                    .foregroundStyle(appState.isConnected ? Color(hex: "10B981") : .gray)
            }
            
            Spacer()
            
            // User Status
            Button(action: { showEditProfileSheet = true }) {
                HStack(spacing: 8) {
                    Text(appState.profileAvatar)
                        .font(.system(size: 16))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                    
                    Text(appState.profileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    
    private var phonePane: some View {
        VStack(spacing: 24) {
            Spacer()
            
            if appState.isConnected {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 64))
                    .foregroundColor(Color(hex: "3B82F6"))
                    .shadow(color: Color(hex: "3B82F6").opacity(0.3), radius: 10)
                
                Text("Phone Mirroring Active")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("The live screen of your Android device is mirrored in a floating window.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                Button(action: {
                    PhoneWindowController.shared.showMirror()
                }) {
                    Text("Bring Window to Front")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color(hex: "3B82F6"))
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Image(systemName: "iphone.slash")
                    .font(.system(size: 64))
                    .foregroundColor(.gray)
                
                Text("Waiting for Android device...")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Please pair and connect your Android device from the Devices tab or enter manual PIN to enable Phone Mirroring.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if appState.isConnected {
                PhoneWindowController.shared.showMirror()
            }
        }
    }
    
    // MARK: - Dashboard Content Pane (No CPU/RAM/SSD System Monitor; Battery info in Connected Card)
    
    private var dashboardPane: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                connectedHeroCard
                
                HStack(alignment: .top, spacing: 16) {
                    yourDevicesCard
                        .frame(maxWidth: .infinity)
                    
                    quickActionsCard
                        .frame(maxWidth: .infinity)
                }
                
                diagnosticsPanel
            }
            .padding(20)
        }
    }

    private var diagnosticsPanel: some View {
        BlueprintCard(title: "Diagnostics & Security") {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: { withAnimation { showDiagnostics.toggle() } }) {
                    HStack {
                        Label("System Metrics & Telemetry", systemImage: "gauge.with.dots.needle.33percent")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.gray)
                    }
                }
                .buttonStyle(.plain)
                
                if showDiagnostics {
                    Divider().opacity(0.1).padding(.vertical, 4)
                    
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                        GridRow {
                            Text("Connection Quality")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                            HStack(spacing: 6) {
                                Circle().fill(appState.isConnected ? Color(hex: "10B981") : Color.red).frame(width: 6, height: 6)
                                Text(appState.isConnected ? "Secure Channel Active" : "Disconnected").font(.system(size: 11)).foregroundStyle(.white)
                            }
                        }
                        GridRow {
                            Text("Latency (RTT)")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                            Text(appState.isConnected ? String(format: "%.1f ms", appState.remotePingRtt) : "N/A")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                        }
                        GridRow {
                            Text("Encryption Standard")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                            Text("TLS 1.3 (WSS / AES-256-GCM)")
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(hex: "06B6D4"))
                        }
                        GridRow {
                            Text("Permissions Status")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.gray)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: permissionManager.isAccessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(permissionManager.isAccessibilityGranted ? .green : .red)
                                    Text("Accessibility API (Cursor Control)").font(.system(size: 10))
                                }
                                HStack(spacing: 4) {
                                    let screenGranted = permissionManager.hasPermission(.screenRecording)
                                    Image(systemName: screenGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(screenGranted ? .green : .red)
                                    Text("Screen Recording (Remote Desktop)").font(.system(size: 10))
                                }
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Active Connection Hero Card (Real-Time Battery & Active Session Details)

    private var connectedHeroCard: some View {
        let macPctString = "\(Int(appState.macBatteryPercent))%"
        let macIsCharging = appState.isMacCharging
        
        return BlueprintCard(title: "Active Connection") {
            VStack(spacing: 16) {
                HStack {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "3B82F6")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 44, height: 44)
                            
                            Image(systemName: appState.isConnected ? "iphone" : "iphone.slash")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(appState.isConnected ? (!appState.connectedDeviceName.isEmpty ? appState.connectedDeviceName : (appState.activeConnectedDevice?.name ?? "Android Companion")) : "No active device connected")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(appState.isConnected ? Color(hex: "10B981") : Color.gray)
                                    .frame(width: 7, height: 7)
                                Text(appState.isConnected ? "Connected • Android Link" : "Host: \(DeviceIdentity.deviceName)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(appState.isConnected ? Color(hex: "10B981") : .gray)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if appState.isConnected {
                        Button("Disconnect") {
                            appState.disconnectActiveDevice()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button("Pair Device") {
                            PairingWindowManager.shared.showPairingWindow()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "6366F1"))
                    }
                }
                
                Divider().opacity(0.15)
                
                // Battery Metrics (Android battery shown ONLY when connected)
                HStack(spacing: 40) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mac Battery (Local Host)")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                        Text(macPctString)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                        Text(macIsCharging && appState.macBatteryPercent < 100 ? "Charging ⚡" : (appState.isMacOnACPower || appState.macBatteryPercent >= 100 ? "Power Adapter 🔌" : "On Battery 🔋"))
                            .font(.system(size: 10))
                            .foregroundStyle((macIsCharging || appState.isMacOnACPower || appState.macBatteryPercent >= 100) ? Color(hex: "10B981") : .gray)
                    }
                    
                    if appState.isConnected {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Android Battery")
                                .font(.system(size: 11))
                                .foregroundStyle(.gray)
                            Text(appState.androidBatteryPercent != nil ? "\(appState.androidBatteryPercent!)%" : "--%")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                            Text((appState.isAndroidCharging == true) ? "Charging (\(appState.androidPowerSource ?? "AC")) ⚡" : "On Battery 🔋")
                                .font(.system(size: 10))
                                .foregroundStyle((appState.isAndroidCharging == true) ? Color(hex: "10B981") : .gray)
                        }
                    }
                    
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - Detail Content Panes

    private var yourDevicesCard: some View {
        BlueprintCard(title: "Nearby Devices") {
            VStack(alignment: .leading, spacing: 10) {
                let unpairedDevices = appState.discoveredAndroidDevices.filter { device in
                    if appState.isConnected {
                        if device.id == appState.connectedDeviceId {
                            return false
                        }
                        let activeName = !appState.connectedDeviceName.isEmpty ? appState.connectedDeviceName : (appState.activeConnectedDevice?.name ?? "")
                        if !activeName.isEmpty && device.name.localizedCaseInsensitiveCompare(activeName) == .orderedSame {
                            return false
                        }
                    }
                    return true
                }
                
                if unpairedDevices.isEmpty {
                    VStack(spacing: 8) {
                        Text("No unpaired devices available")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                        Text("Ensure LinkOS is running on your Android device.")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ForEach(unpairedDevices) { device in
                        DeviceBlueprintRow(
                            name: device.name,
                            subtitle: "\(device.model) • \(device.host)",
                            statusText: "Available",
                            statusColor: .blue,
                            batteryText: nil,
                            iconName: "iphone"
                        )
                    }
                }
                
                Spacer(minLength: 12)
                
                Button(action: {
                    PairingWindowManager.shared.showPairingWindow()
                }) {
                    HStack {
                        Image(systemName: "plus")
                        Text("Pair New Device")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "3B82F6")], startPoint: .leading, endPoint: .trailing))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var devicesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                connectedHeroCard
                yourDevicesCard
            }
            .padding(20)
        }
    }
    
    private var remoteDesktopPane: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Real-Time Desktop Stream & Control")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }
            
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "171A21"))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                
                if !PermissionManager.shared.hasPermission(.screenRecording) {
                    VStack(spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color(hex: "F59E0B"))
                        Text("Screen Recording Permission Required")
                            .font(.headline).foregroundStyle(.white)
                        Text("LinkOS requires Screen Recording permission to stream display frames.")
                            .font(.subheadline).foregroundStyle(.gray)
                        
                        Button("Open System Settings...") {
                            PermissionManager.shared.openSystemSettings(for: .screenRecording)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: "3B82F6"))
                    }
                    .padding(20)
                } else if appState.isConnected {
                    VStack(spacing: 12) {
                        Image(systemName: "display")
                            .font(.system(size: 40))
                            .foregroundStyle(Color(hex: "3B82F6"))
                        Text("Active Remote Desktop Server Stream")
                            .font(.headline).foregroundStyle(.white)
                        Text("Broadcasting macOS display frame buffers securely via WebSocket...")
                            .font(.subheadline).foregroundStyle(.gray)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.gray)
                        Text("Remote Desktop Locked")
                            .font(.headline).foregroundStyle(.white)
                        Text("Pair and connect an Android device to start screen stream.")
                            .font(.subheadline).foregroundStyle(.gray)
                    }
                }
            }
            .frame(height: 420)
        }
        .padding(20)
    }

    private var cameraContinuityPane: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Camera Continuity Webcam Stream")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                
                // Connection indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(cameraFrame != nil ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(cameraFrame != nil ? "Live Feed Active" : "Waiting for Device...")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
                .cornerRadius(12)
            }
            
            HStack(spacing: 20) {
                // Live Stream Frame
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: "171A21"))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    
                    if let img = cameraFrame {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                            .padding(8)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Starting Android Camera Stream...")
                                .font(.headline).foregroundStyle(.white)
                            Text("Make sure the LinkOS app is running on your Android device.")
                                .font(.subheadline).foregroundStyle(.gray)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 250, maxHeight: .infinity)
                
                // Sidebar Control panel
                VStack(alignment: .leading, spacing: 18) {
                    Text("CONTROL PANEL")
                        .font(.caption2.bold())
                        .foregroundStyle(.gray)
                    
                    Divider().opacity(0.1)
                    
                    // Flash Toggle
                    Button(action: {
                        isCameraFlashActive.toggle()
                        Task {
                            await CameraReceiverService.shared.sendToggleFlashCommand(enabled: isCameraFlashActive)
                        }
                    }) {
                        HStack {
                            Image(systemName: isCameraFlashActive ? "flash.on.fill" : "flash.off.fill")
                                .foregroundStyle(isCameraFlashActive ? .orange : .white)
                            Text("Toggle Device Flash")
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    // Switch camera lens
                    Button(action: {
                        Task {
                            await CameraReceiverService.shared.sendSwitchLensCommand()
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                            Text("Switch Lens (Front/Rear)")
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        captureCurrentCameraFrame()
                    }) {
                        HStack {
                            Image(systemName: "camera.fill")
                                .foregroundStyle(.blue)
                            Text("Capture Image")
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(cameraFrame == nil)
                    
                    // Zoom Slider
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Digital Zoom")
                            Spacer()
                            Text(String(format: "%.1fx", cameraZoomRatio))
                                .foregroundStyle(.blue)
                        }
                        .font(.subheadline)
                        
                        Slider(value: Binding(
                            get: { self.cameraZoomRatio },
                            set: { newValue in
                                self.cameraZoomRatio = newValue
                                Task {
                                    await CameraReceiverService.shared.sendZoomCommand(ratio: newValue)
                                }
                            }
                        ), in: 1.0...5.0, step: 0.1)
                    }
                    
                    Divider().opacity(0.1)
                    
                    // Resolution Selector
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stream Quality")
                            .font(.subheadline)
                        Picker("", selection: $selectedResolution) {
                            Text("480p (Fast)").tag("480p")
                            Text("720p (HD)").tag("720p")
                            Text("1080p (FHD)").tag("1080p")
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    Spacer()
                }
                .frame(width: 220)
                .padding()
                .background(Color.white.opacity(0.02))
                .cornerRadius(16)
            }
        }
        .padding(20)
        .onAppear {
            Task {
                let payload = "{\"action\":\"start_camera\"}".data(using: .utf8)!
                let startMsg = MessageRouter.createEvent(channel: "camera", payload: payload)
                await AppState.shared.connectionManager?.broadcast(startMsg)
            }
        }
        .onDisappear {
            Task {
                let payload = "{\"action\":\"stop_camera\"}".data(using: .utf8)!
                let stopMsg = MessageRouter.createEvent(channel: "camera", payload: payload)
                await AppState.shared.connectionManager?.broadcast(stopMsg)
            }
        }
    }

    private var trackpadPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            BlueprintCard(title: "Trackpad & Keyboard Input Control") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.tap.fill")
                            .font(.title2)
                            .foregroundStyle(Color(hex: "10B981"))
                        VStack(alignment: .leading) {
                            Text("Dedicated Wireless Trackpad Server")
                               .font(.headline).foregroundStyle(.white)
                            Text("Receives touch gestures, mouse clicks, media keys, and soft keyboard input.")
                               .font(.subheadline).foregroundStyle(.gray)
                        }
                    }
                    Divider().opacity(0.15)
                    Text("Supported Remote Commands:")
                        .font(.caption).foregroundStyle(.gray)
                    Text("• 1-Finger Cursor Movement & Tap Click\n• Dedicated Vertical Scroll Zone\n• Mouse Left / Right Click Buttons\n• Mission Control & Launchpad Shortcuts\n• Media Keys (Volume, Brightness, Playback)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .padding(20)
    }
    
    private var filesPane: some View {
        AndroidFileBrowserView()
            .environmentObject(appState)
    }
    
    private var clipboardPane: some View {
        UniversalClipboardView()
    }
    
    private var terminalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Interactive Mac PTY Shell")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("Live, direct Zsh terminal session running locally on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
            }
            
            // Console output
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localTerminalOutput)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .padding()
            }
            .frame(height: 300)
            .background(Color.black)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
            
            // Text input row
            HStack {
                TextField("Type command and press enter...", text: $localTerminalInput, onCommit: {
                    sendLocalTerminalInput()
                })
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                
                Button(action: { sendLocalTerminalInput() }) {
                    Text("Send")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color(hex: "34D399"))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .onAppear {
            startLocalTerminalSession()
        }
        .onDisappear {
            stopLocalTerminalSession()
        }
    }
    
    private func startLocalTerminalSession() {
        guard localSession == nil else { return }
        let session = TerminalSession()
        session.onOutput = { data in
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self.localTerminalOutput += text
            }
        }
        do {
            try session.startSession()
            self.localSession = session
        } catch {
            self.localTerminalOutput += "\n[Failed to start shell: \(error.localizedDescription)]\n"
        }
    }
    
    private func stopLocalTerminalSession() {
        localSession?.stopSession()
        localSession = nil
    }
    
    private func sendLocalTerminalInput() {
        guard let session = localSession, !localTerminalInput.isEmpty else { return }
        let line = localTerminalInput + "\n"
        if let data = line.data(using: .utf8) {
            session.writeInput(data)
        }
        localTerminalInput = ""
    }
    
    private var aiAgentPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Mac Automation Agent")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Type natural language instructions to launch apps, capture displays, or mute sounds.")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                Spacer()
                Button(action: { showAISettingsPopover = true }) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAISettingsPopover, arrowEdge: .trailing) {
                    AISettingsPopoverContent(
                        selectedModel: $selectedModel,
                        onAISelected: {
                            showAISettingsPopover = false
                            showAIProviderSheet = true
                        },
                        onCustomCommands: {
                            showAISettingsPopover = false
                            showCustomCommandsSheet = true
                        }
                    )
                }
                .sheet(isPresented: $showAIProviderSheet) {
                    AIProviderConfigSheet(isPresented: $showAIProviderSheet)
                }
                .sheet(isPresented: $showCustomCommandsSheet) {
                    CustomCommandsManagerSheet(isPresented: $showCustomCommandsSheet)
                }
            }
            
            // Console response logs
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(aiResponseLog, id: \.self) { log in
                        HStack(alignment: .top, spacing: 8) {
                            Text(">")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Color(hex: "EC4899"))
                            Text(log)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .background(Color.black.opacity(0.4))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
            
            // Input prompt bar
            HStack(spacing: 12) {
                TextField("Ask AI to perform automation...", text: $aiPrompt)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .font(.system(size: 13))
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                
                Button(action: { executeAIPrompt() }) {
                    if isExecutingAI {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Execute")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(hex: "EC4899"))
                            .cornerRadius(8)
                    }
                }
                .buttonStyle(.plain)
                .disabled(aiPrompt.isEmpty || isExecutingAI)
            }
            
            // Quick suggestions
            HStack(spacing: 8) {
                Text("Try:")
                    .font(.caption)
                    .foregroundStyle(.gray)
                
                Button("Mute volume") { aiPrompt = "mute volume" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                
                Button("Take screenshot") { aiPrompt = "take screenshot" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                
                Button("Open Safari") { aiPrompt = "open Safari" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(20)
    }
    
    private func executeAIPrompt() {
        guard !aiPrompt.isEmpty else { return }
        let promptCopy = aiPrompt
        aiResponseLog.append("User prompt: '\(promptCopy)'")
        aiPrompt = ""
        isExecutingAI = true
        
        Task.detached(priority: .userInitiated) {
            let engine = AIEngine.shared
            do {
                let response = try await engine.executeNaturalLanguageCommand(prompt: promptCopy)
                await MainActor.run {
                    self.aiResponseLog.append("AI response: \(response.text)")
                }
                
                let executor = CommandExecutor()
                for action in response.suggestedActions {
                    let (success, details) = await executor.execute(action: action)
                    await MainActor.run {
                        self.aiResponseLog.append(success ? "Action success! \(details)" : "Action failed: \(details)")
                    }
                }
            } catch {
                let errorMsg = error.localizedDescription
                await MainActor.run {
                    self.aiResponseLog.append("AI execution error: \(errorMsg)")
                }
            }
            await MainActor.run {
                self.isExecutingAI = false
            }
        }
    }
    
    private var streamDeckPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shortcuts Grid & Macro Editor")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Configure your macros. Changes automatically sync to Android device grid companion.")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                Spacer()
                
                TextField("Search macros...", text: $streamDeckSearchQuery)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 150)
                
                Button(action: {
                    let newBtn = StreamDeckButtonConfig(
                        id: UUID().uuidString,
                        position: streamDeckService.currentGrid.buttons.count,
                        label: "New Macro",
                        iconName: "wand.and.stars",
                        backgroundColorHex: "6366F1",
                        actionType: "NONE",
                        actionPayload: [:],
                        isToggle: false,
                        toggleState: false
                    )
                    streamDeckService.currentGrid.buttons.append(newBtn)
                    streamDeckService.saveGrid()
                    editingButton = newBtn
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Add new Macro tile")
            }
            
            let filteredButtons = streamDeckService.currentGrid.buttons.filter {
                streamDeckSearchQuery.isEmpty || $0.label.localizedCaseInsensitiveContains(streamDeckSearchQuery)
            }
            
            if filteredButtons.isEmpty && !streamDeckSearchQuery.isEmpty {
                Text("No macros match your search.")
                    .font(.subheadline)
                    .foregroundStyle(.gray)
                    .padding()
            }
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                ForEach(filteredButtons) { btn in
                    Button(action: { editingButton = btn }) {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: btn.backgroundColorHex).opacity(0.15))
                                    .frame(width: 46, height: 46)
                                if btn.iconName.hasPrefix("/") || btn.iconName.contains(".png"),
                                   let nsImage = NSImage(contentsOfFile: btn.iconName) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 26, height: 26)
                                } else {
                                    Image(systemName: btn.iconName)
                                        .font(.system(size: 20, weight: .bold))
                                        .foregroundStyle(Color(hex: btn.backgroundColorHex))
                                }
                            }
                            
                            VStack(spacing: 2) {
                                Text(btn.label)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(btn.actionType)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .sheet(item: $editingButton) { btn in
            StreamDeckEditorSheet(button: btn, onSave: { updated in
                if let idx = streamDeckService.currentGrid.buttons.firstIndex(where: { $0.id == updated.id }) {
                    streamDeckService.currentGrid.buttons[idx] = updated
                    streamDeckService.saveGrid()
                }
                editingButton = nil
            }, onDelete: {
                streamDeckService.currentGrid.buttons.removeAll(where: { $0.id == btn.id })
                streamDeckService.saveGrid()
                editingButton = nil
            })
        }
    }
    
    private var quickActionsCard: some View {
        BlueprintCard(title: "Quick Actions") {
            VStack(spacing: 10) {
                QuickActionRow(title: "Remote Desktop", subtitle: "Control your devices", icon: "desktopcomputer", accent: Color(hex: "3B82F6"))
                QuickActionRow(title: "Trackpad & Keyboard", subtitle: "Wireless input control", icon: "hand.tap", accent: Color(hex: "10B981"))
                QuickActionRow(title: "File Explorer", subtitle: "Browse & manage files", icon: "folder", accent: Color(hex: "06B6D4"))
                QuickActionRow(title: "Universal Clipboard", subtitle: "Sync across devices", icon: "doc.on.clipboard", accent: Color(hex: "8B5CF6"))
                QuickActionRow(title: "AI Mac Agent", subtitle: "Ask, Automate, Done.", icon: "brain", accent: Color(hex: "EC4899"))
                QuickActionRow(title: "Open Terminal", subtitle: "Command line access", icon: "terminal", accent: Color(hex: "34D399"))
            }
        }
    }
}

// MARK: - Helper Components

struct SidebarSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = title {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.gray)
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
            }
            content()
        }
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color(hex: "3B82F6") : .gray)
                    .frame(width: 18)
                
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : (isHovered ? .white : .gray))
                
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.white.opacity(0.08) : (isHovered ? Color.white.opacity(0.04) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct BlueprintCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
            
            content()
        }
        .padding(16)
        .background(Color(hex: "171A21"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct DeviceBlueprintRow: View {
    let name: String
    let subtitle: String
    let statusText: String
    let statusColor: Color
    let batteryText: String?
    let iconName: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(.blue)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct QuickActionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let accent: Color
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(accent)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.gray.opacity(0.5))
        }
        .background(Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Developer Performance HUD Overlay

extension MainDashboardView {
    private var debugHUDView: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("LINKOS PERFORMANCE HUD")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(hex: "10B981"))
            
            Divider().background(Color.white.opacity(0.1))
            
            VStack(alignment: .leading, spacing: 3) {
                hudRow(label: "State", value: appState.isConnected ? "CONNECTED" : "DISCONNECTED")
                hudRow(label: "RTT Latency", value: String(format: "%.1f ms", ConnectionStateManager.shared.rttMs))
                hudRow(label: "QoS Profile", value: ConnectionStateManager.shared.qos.profile.rawValue.uppercased())
                hudRow(label: "Stream FPS", value: "\(ConnectionStateManager.shared.qos.currentFPS) FPS")
                hudRow(label: "Target Bitrate", value: String(format: "%.1f Mbps", Double(ConnectionStateManager.shared.qos.targetBitrate) / 1_000_000.0))
                hudRow(label: "Bytes Recv", value: formatBytes(ConnectionStateManager.shared.bytesReceived))
                hudRow(label: "Bytes Sent", value: formatBytes(ConnectionStateManager.shared.bytesSent))
                hudRow(label: "Reconnects", value: "\(ConnectionStateManager.shared.reconnectCount)")
            }
            .font(.system(size: 9, design: .monospaced))
        }
        .padding(10)
        .frame(width: 220)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .padding(16)
        .shadow(radius: 6)
    }
    
    private func hudRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundStyle(.gray)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
        }
    }
    
    private func formatBytes(_ count: UInt64) -> String {
        if count < 1024 {
            return "\(count) B"
        } else if count < 1024 * 1024 {
            return String(format: "%.1f KB", Double(count) / 1024.0)
        } else {
            return String(format: "%.1f MB", Double(count) / (1024.0 * 1024.0))
        }
    }
    
    private func captureCurrentCameraFrame() {
        guard let img = cameraFrame else {
            LinkOSLogger.shared.error("Cannot capture: No active camera stream frame", category: .media)
            return
        }
        
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let targetDir = homeDir.appendingPathComponent("Downloads/LinkOS")
        try? fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let finalURL = targetDir.appendingPathComponent("clicked_pic_\(timestamp).jpg")
        
        guard let tiffData = img.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) else {
            LinkOSLogger.shared.error("Failed to convert NSImage to JPEG data", category: .media)
            return
        }
        
        do {
            try jpegData.write(to: finalURL)
            LinkOSLogger.shared.info("Camera Continuity frame captured and saved: \(finalURL.path)", category: .media)
            
            let content = UNMutableNotificationContent()
            content.title = "Photo Captured"
            content.subtitle = "Saved to Downloads/LinkOS"
            content.body = "Ready to view."
            content.userInfo = ["file_path": finalURL.path]
            content.sound = .default
            
            let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + finalURL.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: finalURL, to: tempFileURL)
                if let attachment = try? UNNotificationAttachment(identifier: UUID().uuidString, url: tempFileURL, options: nil) {
                    content.attachments = [attachment]
                }
            } catch {
                LinkOSLogger.shared.error("Failed to copy camera picture to temp dir for notification attachment: \(error)", category: .media)
            }
            
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    LinkOSLogger.shared.error("Failed to schedule UNNotificationRequest for camera: \(error.localizedDescription)", category: .media)
                }
            }
            
            NotificationCenter.default.post(name: NSNotification.Name("CameraContinuityCapturedSuccessfully"), object: nil)
            NotificationCenter.default.post(name: Notification.Name("LinkOSFileReceived"), object: nil, userInfo: ["filePath": finalURL.path])
        } catch {
            LinkOSLogger.shared.error("Failed to write JPEG data: \(error.localizedDescription)", category: .media)
        }
    }
}

func extractAppIcon(atAppPath appPath: String) -> String? {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
    let iconsDir = appSupport.appendingPathComponent("LinkOS").appendingPathComponent("Icons")
    try? fm.createDirectory(at: iconsDir, withIntermediateDirectories: true)
    
    let appURL = URL(fileURLWithPath: appPath)
    let appName = appURL.deletingPathExtension().lastPathComponent
    let targetIconURL = iconsDir.appendingPathComponent("\(appName)_\(UUID().uuidString.prefix(6)).png")
    
    let icon = NSWorkspace.shared.icon(forFile: appPath)
    
    let size = NSSize(width: 128, height: 128)
    let resizedImage = NSImage(size: size)
    resizedImage.lockFocus()
    icon.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: icon.size), operation: .copy, fraction: 1.0)
    resizedImage.unlockFocus()
    
    guard let tiffData = resizedImage.tiffRepresentation,
          let bitmapRep = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        return nil
    }
    
    do {
        try pngData.write(to: targetIconURL)
        return targetIconURL.path
    } catch {
        LinkOSLogger.shared.error("Failed to write extracted app icon: \(error.localizedDescription)", category: .files)
        return nil
    }
}

struct StreamDeckEditorSheet: View {
    @State var button: StreamDeckButtonConfig
    var onSave: (StreamDeckButtonConfig) -> Void
    var onDelete: () -> Void
    
    let actionTypes = ["SYSTEM_CONTROL", "LAUNCH_APP", "OPEN_FOLDER", "NONE"]
    
    @State private var pickerColor = Color.indigo
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Macro Tile")
                .font(.headline)
                .foregroundStyle(.white)
            
            Form {
                Section("General") {
                    TextField("Label", text: $button.label)
                    
                    HStack {
                        TextField("Icon Symbol/Emoji", text: $button.iconName)
                        
                        Button("Choose App...") {
                            let openPanel = NSOpenPanel()
                            openPanel.allowedContentTypes = [.application]
                            openPanel.allowsMultipleSelection = false
                            openPanel.canChooseDirectories = false
                            openPanel.canChooseFiles = true
                            if openPanel.runModal() == .OK, let appURL = openPanel.url {
                                if let extractedPath = extractAppIcon(atAppPath: appURL.path) {
                                    button.iconName = extractedPath
                                    button.label = appURL.deletingPathExtension().lastPathComponent
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    ColorPicker("Tile Theme Color", selection: $pickerColor)
                        .onChange(of: pickerColor) { _, newColor in
                            if let hex = newColor.toHex() {
                                button.backgroundColorHex = hex
                            }
                        }
                }
                
                Section("Action") {
                    Picker("Action Type", selection: $button.actionType) {
                        ForEach(actionTypes, id: \.self) { type in
                            Text(type).tag(type)
                        }
                    }
                }
                
                Section("Parameters") {
                    if button.actionType == "SYSTEM_CONTROL" {
                        Picker("Control Setting", selection: Binding(
                            get: { button.actionPayload["setting"] ?? "mute" },
                            set: { button.actionPayload["setting"] = $0 }
                        )) {
                            Text("Mute/Unmute Audio").tag("mute")
                            Text("Lock Screen").tag("lock")
                            Text("Play / Pause Media").tag("playpause")
                            Text("Volume Up").tag("vol_up")
                            Text("Volume Down").tag("vol_down")
                            Text("Brightness Up").tag("brightness_up")
                            Text("Brightness Down").tag("brightness_down")
                        }
                        .pickerStyle(.menu)
                    } else if button.actionType == "LAUNCH_APP" {
                        HStack {
                            TextField("App Path or Bundle ID", text: Binding(
                                get: { button.actionPayload["app_name"] ?? "" },
                                set: { button.actionPayload["app_name"] = $0 }
                            ))
                            
                            Button("Browse...") {
                                let openPanel = NSOpenPanel()
                                openPanel.allowedContentTypes = [.application]
                                openPanel.allowsMultipleSelection = false
                                openPanel.canChooseDirectories = false
                                openPanel.canChooseFiles = true
                                if openPanel.runModal() == .OK, let appURL = openPanel.url {
                                    button.actionPayload["app_name"] = appURL.path
                                    if button.label == "New Macro" || button.label.isEmpty {
                                        button.label = appURL.deletingPathExtension().lastPathComponent
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if button.actionType == "OPEN_FOLDER" {
                        HStack {
                            TextField("Folder Path", text: Binding(
                                get: { button.actionPayload["path"] ?? "" },
                                set: { button.actionPayload["path"] = $0 }
                            ))
                            
                            Button("Browse...") {
                                let openPanel = NSOpenPanel()
                                openPanel.canChooseFiles = false
                                openPanel.canChooseDirectories = true
                                openPanel.allowsMultipleSelection = false
                                if openPanel.runModal() == .OK, let folderURL = openPanel.url {
                                    button.actionPayload["path"] = folderURL.path
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            
            HStack(spacing: 12) {
                Button("Delete Tile", role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                
                Spacer()
                
                Button("Cancel") {
                    onSave(button)
                }
                .buttonStyle(.bordered)
                
                Button("Save Macro") {
                    onSave(button)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "6366F1"))
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 20)
        .frame(width: 440, height: 420)
        .background(Color(hex: "0D0F13"))
        .onAppear {
            pickerColor = Color(hex: button.backgroundColorHex)
        }
    }
}

struct EditProfileView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState
    
    @State private var name = ""
    @State private var deviceName = ""
    @State private var selectedAvatar = "💻"
    
    let avatars = ["💻", "📱", "🦊", "🚀", "💡", "🎨", "🛠", "🔑", "🍿", "🎮", "🏎", "👾"]
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Profile Settings")
                .font(.headline)
                .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("PROFILE NAME")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "6366F1"))
                TextField("Hritesh", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("MAC DEVICE NAME")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "34D399"))
                TextField("My Mac", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("AVATAR")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "06B6D4"))
                
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                    ForEach(avatars, id: \.self) { avatar in
                        Text(avatar)
                            .font(.system(size: 20))
                            .frame(width: 36, height: 36)
                            .background(selectedAvatar == avatar ? Color(hex: "6366F1").opacity(0.2) : Color.white.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selectedAvatar == avatar ? Color(hex: "6366F1") : Color.white.opacity(0.1), lineWidth: 1.5)
                            )
                            .onTapGesture {
                                selectedAvatar = avatar
                            }
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Save") {
                    if !name.isEmpty { appState.profileName = name }
                    if !deviceName.isEmpty { appState.customDeviceName = deviceName }
                    appState.profileAvatar = selectedAvatar
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "6366F1"))
            }
        }
        .padding()
        .frame(width: 320, height: 380)
        .background(Color(hex: "0B0F19"))
        .onAppear {
            name = appState.profileName
            deviceName = appState.customDeviceName
            selectedAvatar = appState.profileAvatar
        }
    }
}

struct AISettingsPopoverContent: View {
    @Binding var selectedModel: AIEngine.AIModelType
    var onAISelected: () -> Void
    var onCustomCommands: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)
                .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    selectedModel = .local
                    AIEngine.shared.setLocalProvider()
                }) {
                    HStack {
                        Image(systemName: selectedModel == .local ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(.pink)
                        Text("Local")
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                
                Button(action: {
                    selectedModel = .ai
                    onAISelected()
                }) {
                    HStack {
                        Image(systemName: selectedModel == .ai ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(.pink)
                        Text("AI (Cloud/Custom)")
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            Button(action: {
                onCustomCommands()
            }) {
                HStack {
                    Text("Custom Commands...")
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 220)
        .background(Color(hex: "1F2937"))
    }
}

struct TrackpadSettingsPane: View {
    @AppStorage("linkos_trackpad_cursor_sensitivity") private var cursorSensitivity = 1.00
    @AppStorage("linkos_trackpad_scrolling_sensitivity") private var scrollingSensitivity = 1.00
    @AppStorage("linkos_trackpad_scroll_direction_natural") private var scrollDirectionNatural = true
    @AppStorage("linkos_trackpad_tap_to_click") private var tapToClick = true
    @AppStorage("linkos_trackpad_two_finger_secondary_click") private var twoFingerSecondaryClick = true
    @AppStorage("linkos_trackpad_three_finger_drag") private var threeFingerDrag = true
    @AppStorage("linkos_trackpad_five_finger_zoom") private var fiveFingerZoom = true
    @AppStorage("linkos_trackpad_pointer_acceleration") private var pointerAcceleration = "Normal (Default)"
    @AppStorage("linkos_trackpad_motion_smoothing") private var motionSmoothing = "Off"
    @AppStorage("linkos_trackpad_precision_mode") private var precisionMode = false
    @AppStorage("linkos_trackpad_gaming_mode") private var gamingMode = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trackpad & Keyboard Settings")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Configure cursor movement, gestures, touch response, and keyboard mapping.")
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                }
                
                // Sensitivity Card
                BlueprintCard(title: "Cursor & Scrolling Sensitivity") {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Cursor Sensitivity")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(String(format: "%.2fx", cursorSensitivity))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.gray)
                            }
                            Slider(value: $cursorSensitivity, in: 0.25...3.00, step: 0.05)
                                .tint(Color(hex: "6366F1"))
                        }
                        
                        Divider().opacity(0.1)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Scrolling Sensitivity")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(String(format: "%.2fx", scrollingSensitivity))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.gray)
                            }
                            Slider(value: $scrollingSensitivity, in: 0.25...3.00, step: 0.05)
                                .tint(Color(hex: "10B981"))
                        }
                    }
                }
                
                // Behavior & Gestures Card
                BlueprintCard(title: "Behavior & Gestures") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $scrollDirectionNatural) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Natural Scrolling")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Content tracks finger movement directly.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                        
                        Divider().opacity(0.1)
                        
                        Toggle(isOn: $tapToClick) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Tap to Click")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Tap with one finger to click.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                        
                        Divider().opacity(0.1)
                        
                        Toggle(isOn: $twoFingerSecondaryClick) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Two Finger Secondary Click")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Tap with two fingers for secondary click.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                        
                        Divider().opacity(0.1)
                        
                        Toggle(isOn: $threeFingerDrag) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Two Finger Hold & Drag")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Hold two fingers for 350ms, then slide to drag windows and items.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                        
                        Divider().opacity(0.1)
                        
                        Toggle(isOn: $fiveFingerZoom) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Five Finger Pinch Zoom")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Pinch with five fingers to zoom in or out on Mac.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                    }
                }
                
                // Advanced Tracking Settings
                BlueprintCard(title: "Motion & Advanced Pacing") {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Pointer Acceleration")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Spacer()
                            Picker("", selection: $pointerAcceleration) {
                                Text("Disabled").tag("Disabled")
                                Text("Low").tag("Low")
                                Text("Normal (Default)").tag("Normal (Default)")
                                Text("High").tag("High")
                            }
                            .frame(width: 140)
                        }
                        
                        Divider().opacity(0.1)
                        
                        HStack {
                            Text("Motion Smoothing")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Spacer()
                            Picker("", selection: $motionSmoothing) {
                                Text("Off").tag("Off")
                                Text("Balanced (Default)").tag("Balanced (Default)")
                                Text("Maximum").tag("Maximum")
                            }
                            .frame(width: 140)
                        }
                        
                        Divider().opacity(0.1)
                        
                        Toggle(isOn: $precisionMode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Precision Mode")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Slower movement with high pixel accuracy (great for design work).")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
                        .disabled(gamingMode)
                        
                        Divider().opacity(0.1)
                        
                        Toggle(isOn: $gamingMode) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gaming Mode")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Disables motion smoothing and acceleration for raw, lowest latency.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.gray)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "E11D48")))
                        .disabled(precisionMode)
                    }
                }
                
                // Keyboard Input Card
                BlueprintCard(title: "Keyboard Features & Configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "keyboard")
                                .font(.title3)
                                .foregroundStyle(Color(hex: "6366F1"))
                            Text("Keyboard Integration Active")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        
                        Text("When the soft keyboard is toggled on your phone, keystrokes are received and injected directly to your Mac.")
                            .font(.system(size: 11))
                            .foregroundStyle(.gray)
                        
                        Divider().opacity(0.1)
                        
                        Text("Supported features:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("• Character typing and symbols injection")
                            Text("• Native macOS command shortcuts (Cmd, Option, Shift, Control)")
                            Text("• System special control keys (Esc, Space, Tab, Backspace, Enter)")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                    }
                }
                
                // Reset Button
                Button(action: resetToDefaults) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset Settings to Default")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Color(hex: "0B0C10").ignoresSafeArea())
    }
    
    private func resetToDefaults() {
        cursorSensitivity = 1.00
        scrollingSensitivity = 1.00
        scrollDirectionNatural = true
        tapToClick = true
        twoFingerSecondaryClick = true
        threeFingerDrag = true
        pointerAcceleration = "Normal (Default)"
        motionSmoothing = "Balanced (Default)"
        precisionMode = false
        gamingMode = false
    }
}
