import SwiftUI

/// Menu bar dropdown view — the primary macOS UI surface.
/// Redesigned with premium dark-mode aesthetic, glowing status badges, category icons, and high-contrast typography.
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 10) {
            // Header
            headerSection
            
            Divider()
                .opacity(0.3)
            
            // Devices Section
            devicesSection
            
            Divider()
                .opacity(0.3)
            
            // Quick Actions Section
            actionsSection
            
            Divider()
                .opacity(0.3)
            
            // Footer Section
            footerSection
        }
        .frame(width: 330)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            ZStack {
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
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("LinkOS")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                
                HStack(spacing: 6) {
                    StatusIndicator(isActive: appState.isConnected, activeColor: .green, size: 7)
                    Text(appState.isConnected
                         ? (!appState.connectedDeviceName.isEmpty ? appState.connectedDeviceName : (appState.activeConnectedDevice?.name ?? "Companion Device"))
                         : "No Device Connected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Connection status badge
            if appState.isConnected {
                HStack(spacing: 4) {
                    ConnectionQualityView(quality: appState.connectionQuality)
                    Text(appState.connectionQuality.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }
    
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let device = appState.activeConnectedDevice, appState.isConnected {
                DeviceRow(device: device)
            } else {
                Button(action: { openPairingWindow() }) {
                    HStack(spacing: 10) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pair New Device")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Scan QR code or enter PIN")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }
            
            if !appState.discoveredAndroidDevices.isEmpty && !appState.isConnected {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEARBY DEVICES")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .tracking(1)
                        .padding(.horizontal, 14)
                        .padding(.top, 4)
                    
                    ForEach(appState.discoveredAndroidDevices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone")
                                .font(.system(size: 15))
                                .foregroundStyle(.blue)
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(device.host)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Connect") {
                                appState.connectToAndroidDevice(device: device, method: "PIN")
                            }
                            
                            Text("Ready to pair")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }
        }
    }
    
    private var actionsSection: some View {
        VStack(spacing: 2) {
            MenuBarButton(title: "Open Dashboard", icon: "square.grid.2x2", shortcut: "⌘D") {
                focusOrOpenDashboard()
            }
            MenuBarButton(title: "Pair Device", icon: "qrcode.viewfinder", shortcut: "⌘P") {
                openPairingWindow()
            }
            MenuBarButton(title: "Command Palette", icon: "command", shortcut: "⌘K") {
                showCommandPalette()
            }
        }
        .padding(.horizontal, 6)
    }
    
    private var footerSection: some View {
        HStack {
            Button(action: {
                focusOrOpenDashboard(tab: "Settings")
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                    Text("Settings…")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            
            Spacer()
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                    Text("Quit")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }
    
    // MARK: - Actions
    
    private func openPairingWindow() {
        PairingWindowManager.shared.showPairingWindow()
    }
}

// MARK: - Subviews

struct DeviceRow: View {
    let device: TrustedDevice
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 32, height: 32)
                
                Image(systemName: "iphone")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                
                Text(device.isBlocked ? "Blocked" : "Active Encrypted Session (AES-256)")
                    .font(.system(size: 10))
                    .foregroundStyle(device.isBlocked ? .red : .secondary)
            }
            
            Spacer()
            
            StatusIndicator(isActive: !device.isBlocked, activeColor: .green, size: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct MenuBarButton: View {
    let title: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isHovered ? .blue : .secondary)
                
                Text(title)
                    .font(.system(size: 12, weight: isHovered ? .semibold : .regular))
                
                Spacer()
                
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHovered ? Color.blue.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
