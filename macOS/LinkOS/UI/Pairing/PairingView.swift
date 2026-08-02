import SwiftUI

/// Window Manager for showing native Pairing HUD window directly from AppKit
@MainActor
public final class PairingWindowManager {
    public static let shared = PairingWindowManager()
    private var window: NSWindow?
    
    public func showPairingWindow() {
        closeWindow()
        
        let pairingView = PairingView()
            .environmentObject(AppState.shared)
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.center()
        win.title = "LinkOS Pair Device"
        win.contentView = NSHostingView(rootView: pairingView)
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

enum PairingMethodTab: String, CaseIterable, Identifiable {
    case qr = "QR Code"
    case pin = "PIN Code"
    
    var id: String { self.rawValue }
}

/// Device pairing view — displayed when user initiates pairing with a new device.
struct PairingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = PairingViewModel()
    @State private var selectedTab: PairingMethodTab = .pin
    
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Top Title & Segmented Picker
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedCornerRectangle(radius: 10)
                                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 38, height: 38)
                            
                            Image(systemName: "laptopcomputer.and.iphone")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LinkOS Device Pairing")
                                .font(.system(size: 18, weight: .bold))
                            Text("Secure E2E Encrypted Connection")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    Picker("Pairing Method", selection: $selectedTab) {
                        ForEach(PairingMethodTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedTab) { _, newTab in
                        if newTab == .pin {
                            appState.pairingState = .pinGenerated
                        } else {
                            appState.pairingState = .qrGenerated
                        }
                    }
                }
                
                Divider()
                    .opacity(0.3)
                
                // Content Area
                VStack(spacing: 16) {
                    if selectedTab == .pin {
                        // PIN CODE DISPLAY
                        VStack(spacing: 16) {
                            Text("6-Digit Verification PIN")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .tracking(1)
                            
                            Text(viewModel.numericCode.map { String($0) }.joined(separator: "  "))
                                .font(.system(size: 38, weight: .bold, design: .monospaced))
                                .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color.black.opacity(0.4))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.cyan.opacity(0.4), lineWidth: 1)
                                )
                                .shadow(color: .cyan.opacity(0.2), radius: 10)
                            
                            HStack(spacing: 6) {
                                Image(systemName: "timer")
                                    .font(.system(size: 11))
                                Text("Code expires in \(viewModel.timeRemaining)s")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                            
                            Text("Open LinkOS on your Android phone, tap Connect, and choose 'Pair using PIN'. Select this Mac to enter this code.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                            
                            HStack(spacing: 14) {
                                Button(action: { viewModel.regenerateCode() }) {
                                    Label("Refresh Code", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                
                                Button(action: {
                                    viewModel.cancel()
                                    PairingWindowManager.shared.closeWindow()
                                }) {
                                    Text("Cancel")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        // QR CODE DISPLAY
                        VStack(spacing: 16) {
                            Text("Scan QR Code on Android")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .tracking(1)
                            
                            if let qrImage = viewModel.qrCodeImage {
                                Image(nsImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 190, height: 190)
                                    .padding(14)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .shadow(color: .blue.opacity(0.25), radius: 14, x: 0, y: 4)
                            } else {
                                ProgressView()
                                    .frame(width: 190, height: 190)
                            }
                            
                            Text("Open LinkOS on your Android phone and tap 'Scan QR Code' to connect instantly.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                            
                            Button("Cancel") {
                                viewModel.cancel()
                                PairingWindowManager.shared.closeWindow()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                Spacer()
            }
            .padding(24)
        }
        .frame(width: 480, height: 560)
        .onAppear {
            viewModel.startPairing()
            appState.pairingState = selectedTab == .pin ? .pinGenerated : .qrGenerated
        }
        .onDisappear {
            viewModel.cancel()
        }
    }
}

private struct RoundedCornerRectangle: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

// MARK: - ViewModel

@MainActor
final class PairingViewModel: ObservableObject {
    @Published var qrCodeImage: NSImage?
    @Published var numericCode: String = "------"
    @Published var isWaiting: Bool = false
    @Published var timeRemaining: Int = 120
    
    private var timer: Timer?
    
    func startPairing() {
        regenerateCode()
        isWaiting = true
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timeRemaining > 0 else {
                    self?.regenerateCode()
                    return
                }
                self.timeRemaining -= 1
            }
        }
    }
    
    func regenerateCode() {
        let code = String(format: "%06d", Int.random(in: 0...999999))
        numericCode = code
        timeRemaining = 120
        
        Task { @MainActor in
            AppState.shared.activePairingCode = code
        }
        
        qrCodeImage = generateQRCode(from: createQRPayload(code: code))
        LinkOSLogger.shared.info("[Pairing] Code generated: \(code)", category: .security)
    }
    
    func cancel() {
        timer?.invalidate()
        timer = nil
        isWaiting = false
        Task { @MainActor in
            AppState.shared.activePairingCode = nil
            AppState.shared.destroySession(reason: "User cancelled pairing from UI")
        }
    }
    
    private func createQRPayload(code: String) -> String {
        let localIP = AppState.shared.getLocalIPAddress()
        let payload: [String: Any] = [
            "device_id": DeviceIdentity.deviceId,
            "device_name": DeviceIdentity.deviceName,
            "host": localIP,
            "code": code,
            "port": 52637,
            "protocol_version": 1,
            "expiry": Int(Date().timeIntervalSince1970) + 120,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }
    
    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel")
        
        guard let ciImage = filter.outputImage else { return nil }
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = ciImage.transformed(by: transform)
        
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
