import SwiftUI

// MARK: - Interactive Button Styles & Components

struct ToolbarIconButtonStyle: ButtonStyle {
    var isEnabled: Bool = true
    var isHovered: Bool = false
    var scale: CGFloat = 1.0
    
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(configuration.isPressed ? Color.white.opacity(0.25) : (isHovered && isEnabled ? Color.white.opacity(0.15) : Color.clear))
                .frame(width: 44 * scale, height: 44 * scale)
            
            configuration.label
                .foregroundColor(isEnabled ? .white : .white.opacity(0.35))
                .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
        }
        .frame(width: 44 * scale, height: 44 * scale)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.16), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Filled accent-color circular button — used for the primary toolbar action (⋯ popover).
struct PrimaryToolbarButtonStyle: ButtonStyle {
    var isHovered: Bool = false
    var scale: CGFloat = 1.0

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle()
                .fill(
                    configuration.isPressed
                        ? Color(red: 0, green: 0.44, blue: 0.85)   // pressed: darker accent
                        : (isHovered
                            ? Color(red: 0.15, green: 0.55, blue: 1.0)   // hover: lighter accent
                            : Color(red: 0.0,  green: 0.478, blue: 1.0)) // default: #007AFF
                )
                .frame(width: 38 * scale, height: 38 * scale)

            configuration.label
                .foregroundColor(.white)
                .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
        }
        .frame(width: 44 * scale, height: 44 * scale)
        .contentShape(Circle())
        .shadow(color: Color(red: 0, green: 0.48, blue: 1.0).opacity(isHovered ? 0.45 : 0.25), radius: 6 * scale, x: 0, y: 2 * scale)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Wrapper view that owns hover state for PrimaryToolbarButtonStyle.
struct PrimaryToolbarButtonStyleWrapper: ButtonStyle {
    @State private var isHovered = false
    var scale: CGFloat = 1.0

    func makeBody(configuration: Configuration) -> some View {
        PrimaryToolbarButtonStyle(isHovered: isHovered, scale: scale)
            .makeBody(configuration: configuration)
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

struct InteractiveToolbarButton<Content: View>: View {
    var isEnabled: Bool = true
    var scale: CGFloat = 1.0
    let action: () -> Void
    let content: () -> Content
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action, label: content)
            .buttonStyle(ToolbarIconButtonStyle(isEnabled: isEnabled, isHovered: isHovered, scale: scale))
            .disabled(!isEnabled)
            .onHover { hovering in
                isHovered = hovering
                if hovering && isEnabled {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

struct PopoverMenuItem: View {
    let title: String
    let icon: String
    var tint: Color = .white
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

// MARK: - Dedicated Interactive Toolbar Grab Handle

struct ToolbarDragHandleRepresentable: NSViewRepresentable {
    var isVertical: Bool
    @Binding var isHovered: Bool
    
    class DragHandleView: NSView {
        var isVertical: Bool = false
        var onHover: ((Bool) -> Void)?
        private var trackingArea: NSTrackingArea?
        
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }
        
        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
            NSCursor.openHand.set()
        }
        
        override func mouseExited(with event: NSEvent) {
            onHover?(false)
            NSCursor.arrow.set()
        }
        
        override func mouseDown(with event: NSEvent) {
            NSCursor.closedHand.set()
            nextResponder?.mouseDown(with: event)
        }
        
        override func mouseUp(with event: NSEvent) {
            NSCursor.openHand.set()
            nextResponder?.mouseUp(with: event)
        }
    }
    
    func makeNSView(context: Context) -> DragHandleView {
        let v = DragHandleView()
        v.isVertical = isVertical
        v.onHover = { hover in
            DispatchQueue.main.async { isHovered = hover }
        }
        return v
    }
    
    func updateNSView(_ nsView: DragHandleView, context: Context) {
        nsView.isVertical = isVertical
        nsView.onHover = { hover in
            DispatchQueue.main.async { isHovered = hover }
        }
    }
}

struct ToolbarGrabHandle: View {
    var isVertical: Bool
    @State private var isHovered = false
    
    var body: some View {
        ToolbarDragHandleRepresentable(isVertical: isVertical, isHovered: $isHovered)
            .frame(width: isVertical ? 32 : 24, height: isVertical ? 24 : 32)
            .contentShape(Rectangle())
    }
}

// MARK: - PhoneBottomBar

/// Renders the floating toolbar containing: More (...), Divider, Back, Home, and Recents.
/// Controls feature 44x44 pt touch targets, hover highlights, pressed animations, pointing hand cursors, and debounce protection.
struct PhoneBottomBar: View {
    @ObservedObject var session: PhoneSession
    @ObservedObject var workspace = MirroringWorkspace.shared
    
    init(session: PhoneSession) {
        self.session = session
    }

    @AppStorage("pm_audio_sync") private var audioSync = false
    @AppStorage("pm_volume") private var volume: Double = 0.5
    @AppStorage("pm_always_on_top") private var alwaysOnTop = false

    @State private var selectedTab = 0
    @State private var isRecording = false
    @State private var lastKeySendTime: Date = .distantPast
    @State private var popoverTab: Int = 0
    @State private var macVolume: Double = 0.5
    @State private var lastMacVolumeSetTime: Date = .distantPast
    @State private var macVolumeDebounceTimer: Timer? = nil
    
    private func fetchInitialMacVolume() {
        macVolume = MediaControlService.getSystemVolume()
    }
    
    private func updateMacVolume(_ newVol: Double) {
        macVolumeDebounceTimer?.invalidate()
        let now = Date()
        if now.timeIntervalSince(lastMacVolumeSetTime) > 0.08 {
            lastMacVolumeSetTime = now
            Task { @MainActor in
                MediaControlService.setSystemVolume(newVol)
            }
        } else {
            macVolumeDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                Task { @MainActor in
                    MediaControlService.setSystemVolume(newVol)
                }
            }
        }
    }

    private var isConnected: Bool {
        session.connectionState == .connected
    }
    private var isVertical: Bool {
        guard workspace.dockState != .floating else { return false }
        let edge = workspace.approachingEdge ?? workspace.activeToolbarEdge
        return edge == .left || edge == .right
    }
    
    // Smooth layout transitions
    private var toolbarScale: CGFloat {
        let reference: CGFloat = 260.0
        let available = isVertical ? workspace.phoneWindowFrame.height : workspace.phoneWindowFrame.width
        if available >= reference || available <= 10 { return 1.0 }
        return max(0.55, available / reference)
    }

    private var popoverArrowEdge: Edge {
        let barFrame = workspace.toolbarPanelFrame
        let screenBottom = NSScreen.main?.visibleFrame.minY ?? 0
        let popoverHeight: CGFloat = 380
        
        if workspace.dockState == .floating {
            return (barFrame.minY - popoverHeight < screenBottom) ? .top : .bottom
        }
        
        switch workspace.activeToolbarEdge {
        case .bottom: return .bottom // Arrow on bottom opens popover upward into visible bounds
        case .top:    return .top    // Arrow on top opens popover downward into visible bounds
        case .left:   return .leading
        case .right:  return .trailing
        }
    }

    // MARK: - Body
    //
    // All edges use the same HStack layout. When docked left/right the bar rotates 90° in-place.
    // The panel frame is always (phoneWidth × barThickness) — only orientation changes. Nothing resizes.

    var body: some View {
        let activeEdge = workspace.activeToolbarEdge

        Group {
            if isVertical {
                VStack(spacing: 0) { verticalToolbarContents }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) { horizontalToolbarContents }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 24 * toolbarScale, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).cornerRadius(24 * toolbarScale))
                .overlay(RoundedRectangle(cornerRadius: 24 * toolbarScale, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.4), radius: 10 * toolbarScale, x: 0, y: 4 * toolbarScale)
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: activeEdge)
        .onChange(of: audioSync) { _ in
            let payload: [String: Any] = ["action": "SET_AUDIO_FORWARDING", "enabled": audioSync]
            Task { await session.sendControlMessage(payload) }
        }
        .onChange(of: volume) { _ in
            let payload: [String: Any] = ["action": "SET_VOLUME", "volume": volume]
            Task { await session.sendControlMessage(payload) }
        }
        .onChange(of: alwaysOnTop) { _ in
            DispatchQueue.main.async {
                PhoneWindowController.shared.setAlwaysOnTop(alwaysOnTop)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                PhoneWindowController.shared.setAlwaysOnTop(alwaysOnTop)
            }
        }
    }

    @ViewBuilder
    private var horizontalToolbarContents: some View {
        HStack(spacing: 0) {
            // Left-aligned section: More button and divider
            HStack(spacing: 0) {
                moreButton
                
                Divider()
                    .frame(width: 1, height: 20 * toolbarScale)
                    .background(Color.white.opacity(0.25))
                    .padding(.horizontal, 8 * toolbarScale)
            }
            .padding(.leading, 8 * toolbarScale)
            
            Spacer()
            
            // Navigation buttons (shifted slightly right by Spacer balance)
            HStack(spacing: 24 * toolbarScale) {
                recentsButton   // ■ (Recents)
                homeButton      // ● (Home)
                backButton      // ◀ (Back)
            }
            .padding(.trailing, 20 * toolbarScale) // Balance to keep it mostly centered but shifted right
            
            Spacer()
        }
    }

    @ViewBuilder
    private var verticalToolbarContents: some View {
        VStack(spacing: 0) {
            // Top-aligned section: More button and divider
            VStack(spacing: 0) {
                moreButton
                
                Divider()
                    .frame(width: 20 * toolbarScale, height: 1)
                    .background(Color.white.opacity(0.25))
                    .padding(.vertical, 8 * toolbarScale)
            }
            .padding(.top, 8 * toolbarScale)
            
            Spacer()
            
            // Navigation buttons
            VStack(spacing: 16 * toolbarScale) {
                recentsButton   // ■ (Recents)
                homeButton      // ● (Home)
                backButton      // ◀ (Back)
            }
            .padding(.bottom, 20 * toolbarScale)
            
            Spacer()
        }
    }

    @ViewBuilder
    private var moreButton: some View {
        InteractiveToolbarButton(isEnabled: true, scale: toolbarScale, action: {
            workspace.showControlsPopover.toggle()
        }) {
            Image(systemName: "ellipsis")
                .font(.system(size: 17 * toolbarScale, weight: .bold))
        }
        .popover(isPresented: $workspace.showControlsPopover, arrowEdge: popoverArrowEdge) {
            controlsPopoverView
                .preferredColorScheme(.dark)
                .background(Color.black.opacity(0.85))
        }
    }

    @ViewBuilder
    private var backButton: some View {
        InteractiveToolbarButton(isEnabled: true, scale: toolbarScale, action: {
            sendDebouncedKey("KEY_BACK")
        }) {
            Image(systemName: "arrowtriangle.left.fill")
                .font(.system(size: 15 * toolbarScale))
        }
    }

    @ViewBuilder
    private var homeButton: some View {
        InteractiveToolbarButton(isEnabled: true, scale: toolbarScale, action: {
            sendDebouncedKey("KEY_HOME")
        }) {
            Image(systemName: "circle.fill")
                .font(.system(size: 15 * toolbarScale))
        }
    }

    @ViewBuilder
    private var recentsButton: some View {
        InteractiveToolbarButton(isEnabled: true, scale: toolbarScale, action: {
            sendDebouncedKey("KEY_RECENTS")
        }) {
            Image(systemName: "square.fill")
                .font(.system(size: 14 * toolbarScale))
        }
    }

    private func sendDebouncedKey(_ key: String) {
        let now = Date()
        guard now.timeIntervalSince(lastKeySendTime) >= 0.35 else {
            LinkOSLogger.shared.info("[Toolbar] Debounced duplicate navigation key: \(key)", category: .media)
            return
        }
        lastKeySendTime = now
        LinkOSLogger.shared.info("[Toolbar] Dispatching global navigation key to Android: \(key)", category: .media)
        session.sendKey(key)
    }

    // MARK: - ⋯ Unified Popover
    
    @AppStorage("linkos_developer_mode") private var devModeEnabled = false
    
    private var controlsPopoverView: some View {
        VStack(spacing: 0) {
            // Segmented tab selector if developer mode is active
            if devModeEnabled {
                Picker("", selection: $popoverTab) {
                    Text("General").tag(0)
                    Text("Developer").tag(1)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            
            // Tab contents
            if popoverTab == 0 {
                // GENERAL PAGE
                VStack(alignment: .leading, spacing: 8) {
                    // DISPLAY SECTION
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Display")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        
                        popoverRow(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", label: "Actual Size (1:1)") {
                            workspace.showControlsPopover = false
                            PhoneWindowController.shared.setActualSize()
                        }
                        popoverRow(icon: "rotate.left", label: "Rotate Left") {
                            workspace.showControlsPopover = false
                            PhoneWindowController.shared.rotateWindowAndPreview(left: true)
                        }
                        popoverRow(icon: "rotate.right", label: "Rotate Right") {
                            workspace.showControlsPopover = false
                            PhoneWindowController.shared.rotateWindowAndPreview(left: false)
                        }
                    }
                    
                    Divider().padding(.horizontal, 10)
                    
                    // AUDIO SECTION
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Audio")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        
                        popoverToggleRow(icon: "speaker.wave.2.fill", label: "Internal Audio", binding: $audioSync)
                        
                        // Mac System Volume Slider
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Slider(value: $macVolume, in: 0.0...1.0)
                                .controlSize(.small)
                                .onChange(of: macVolume) { val in
                                    updateMacVolume(val)
                                }
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                        }
                        .padding(.horizontal, 10)
                    }
                    
                    Divider().padding(.horizontal, 10)
                    
                    // CAPTURE SECTION
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Capture")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        
                        popoverRow(icon: "camera.fill", label: "Screenshot") {
                            workspace.showControlsPopover = false
                            PhoneWindowController.shared.takeScreenshot()
                        }
                        popoverToggleRow(
                            icon: isRecording ? "record.circle.fill" : "record.circle",
                            label: isRecording ? "Stop Recording" : "Screen Recording",
                            tint: isRecording ? .red : .white
                        ) {
                            isRecording.toggle()
                            PhoneWindowController.shared.toggleScreenRecording(isRecording)
                        }
                    }
                    
                    Divider().padding(.horizontal, 10)
                    
                    // WINDOW SECTION
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Window")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        
                        popoverToggleRow(icon: "pin.fill", label: "Always on Top", binding: $alwaysOnTop)
                    }
                    
                    Divider().padding(.horizontal, 10)
                    
                    // SYSTEM SECTION
                    VStack(alignment: .leading, spacing: 2) {
                        Text("System")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        
                        popoverRow(icon: "gearshape.fill", label: "Preferences") {
                            workspace.showControlsPopover = false
                            focusOrOpenDashboard(tab: "Settings")
                        }
                    }
                }
                .padding(.top, 6)
            } else {
                // DEVELOPER PAGE
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Developer Tools")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        
                        popoverRow(icon: "chart.bar.fill", label: "Frame Stats") {
                            workspace.showControlsPopover = false
                            workspace.showDevDiagnostics.toggle()
                        }
                        popoverRow(icon: "speedometer", label: "FPS") {
                            workspace.showControlsPopover = false
                            workspace.showDevDiagnostics.toggle()
                        }
                        popoverRow(icon: "rectangle.3.group", label: "Metal Overlay") {
                            workspace.showControlsPopover = false
                            workspace.showDevDiagnostics.toggle()
                        }
                        popoverRow(icon: "hand.draw", label: "Input Visualizer") {
                            workspace.showControlsPopover = false
                            workspace.showDevDiagnostics.toggle()
                        }
                        popoverRow(icon: "doc.text.fill", label: "Logs") {
                            workspace.showControlsPopover = false
                            openDebugConsoleWindow()
                        }
                    }
                }
                .padding(.top, 6)
            }
            
            Spacer(minLength: 0)
            
            Divider().padding(.bottom, 6)
            
            // Disconnect button
            Button(action: {
                workspace.showControlsPopover = false
                PhoneWindowController.disconnectMirror()
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                    Text("Disconnect")
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.vertical, 6)
                .background(Color.red)
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 240, height: devModeEnabled ? (popoverTab == 0 ? 450 : 250) : 380)
        .onAppear {
            fetchInitialMacVolume()
        }
    }
    
    // MARK: - Popover Row Primitives
    
    @ViewBuilder
    private func popoverRow(icon: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        PopoverMenuRow(icon: icon, label: label, tint: tint, action: action)
    }
    
    @ViewBuilder
    private func popoverToggleRow(icon: String, label: String, tint: Color = .white, binding: Binding<Bool>) -> some View {
        PopoverToggleRow(icon: icon, label: label, tint: tint, isOn: binding)
    }
    
    // Overload for inline toggle action (recording)
    @ViewBuilder
    private func popoverToggleRow(icon: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Popover Row Components

struct PopoverMenuRow: View {
    let icon: String
    let label: String
    var tint: Color = .white
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(tint == .white ? .white : tint)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.12) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

struct PopoverToggleRow: View {
    let icon: String
    let label: String
    var tint: Color = .white
    @Binding var isOn: Bool
    
    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Color(hex: "6366F1")))
        .padding(.horizontal, 10)
        .frame(height: 26)
    }
}

