import SwiftUI
import AppKit

/// Native Floating Window Manager for presenting the LinkOS Connection Request dialog.
/// Designed to match the exact Connection Request dialog in the design blueprint.
@MainActor
public final class PairingApprovalWindowManager {
    public static let shared = PairingApprovalWindowManager()
    private var window: NSWindow?
    
    public func showApprovalWindow(request: PendingPairingRequest, onRespond: @escaping (Bool, Bool) -> Void) {
        closeWindow()
        
        let view = PairingApprovalDialogView(request: request) { [weak self] allow, remember in
            onRespond(allow, remember)
            self?.closeWindow()
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.title = "Connection Request"
        win.contentView = NSHostingView(rootView: view)
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = win
    }
    
    public func closeWindow() {
        window?.close()
        window = nil
    }
}

public struct PairingApprovalDialogView: View {
    public let request: PendingPairingRequest
    public let onRespond: (Bool, Bool) -> Void // (allow, remember)
    
    @State private var rememberDevice = true
    
    public init(request: PendingPairingRequest, onRespond: @escaping (Bool, Bool) -> Void) {
        self.request = request
        self.onRespond = onRespond
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            // Header Top Circle Badge
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 56, height: 56)
                
                Image(systemName: "iphone")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)
            
            // Device Title & Subtitle
            VStack(spacing: 4) {
                Text(request.deviceName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                
                Text("\(request.manufacturer) \(request.deviceModel)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                
                Text("wants to connect to this Mac")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray.opacity(0.8))
            }
            
            // Details Table Card
            VStack(spacing: 10) {
                DetailRow(label: "Device", value: "\(request.deviceName) (\(request.id.prefix(8)))", icon: "iphone")
                Divider().opacity(0.1)
                DetailRow(label: "IP Address", value: AppState.shared.getLocalIPAddress(), icon: "network")
                Divider().opacity(0.1)
                DetailRow(label: "First seen", value: "Just now", icon: "clock")
            }
            .padding(14)
            .background(Color(hex: "171A21"))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .padding(.horizontal, 4)
            
            // Remember Toggle Checkbox
            Toggle(isOn: $rememberDevice) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "3B82F6"))
                    Text("Remember this device")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .toggleStyle(.checkbox)
            
            Spacer(minLength: 4)
            
            // Action Buttons Row
            HStack(spacing: 12) {
                Button(action: { onRespond(false, rememberDevice) }) {
                    Text("Reject")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color(hex: "171A21"))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                
                Button(action: { onRespond(true, rememberDevice) }) {
                    Text("Allow Connection")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "3B82F6")], startPoint: .leading, endPoint: .trailing))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .padding(20)
        .background(Color.black)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    let icon: String
    
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}
