import SwiftUI

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var selectedIndex: Int = 0
    @Published var actions: [CommandPaletteAction] = []
    
    private weak var pluginManager: PluginManager?
    
    init(pluginManager: PluginManager? = nil) {
        self.pluginManager = pluginManager
    }
    
    func loadActions() {
        var items: [CommandPaletteAction] = []
        
        let features: [(title: String, tab: String, icon: String, subtitle: String)] = [
            ("Dashboard", "Dashboard", "square.grid.2x2", "View system status and connected devices"),
            ("Clipboard", "Clipboard", "doc.on.clipboard", "Sync clipboard contents between devices"),
            ("Camera Continuity", "Camera Continuity", "camera", "Use your Android device as a webcam"),
            ("Remote Desktop", "Remote Desktop", "desktopcomputer", "Control your Mac/Android desktop"),
            ("Trackpad & Keyboard", "Trackpad & Keyboard", "hand.tap", "Use remote input controls"),
            ("File Explorer", "File Explorer", "folder", "Browse and transfer files"),
            ("Downloads", "Downloads", "arrow.down.circle", "View downloaded files and transfers"),
            ("Notifications", "Notifications", "bell", "Manage mirrored notifications"),
            ("AI Agent", "AI Agent", "brain", "Interact with the local AI agent"),
            ("Macros", "Shortcuts", "square.grid.3x3", "Trigger custom shortcuts and macros"),
            ("Terminal", "Terminal", "terminal", "Open PTY terminal"),
            ("Settings", "Settings", "gearshape", "Configure LinkOS options")
        ]
        
        for feature in features {
            items.append(CommandPaletteAction(
                id: "nav-\(feature.tab.lowercased())",
                title: feature.title,
                subtitle: feature.subtitle,
                icon: feature.icon,
                keywords: [feature.title.lowercased(), "open", "show", "goto", "navigate"],
                category: "Navigation",
                action: {
                    await MainActor.run {
                        focusOrOpenDashboard(tab: feature.tab)
                    }
                }
            ))
        }
        
        if let pm = pluginManager {
            Task {
                let pluginActions = await pm.allCommandPaletteActions()
                await MainActor.run {
                    self.actions = items + pluginActions
                }
            }
        } else {
            self.actions = items
        }
    }
    
    var filteredActions: [CommandPaletteAction] {
        let items = actions
        if query.isEmpty { return items }
        let lower = query.lowercased()
        return items.filter {
            $0.title.lowercased().contains(lower) ||
            ($0.subtitle?.lowercased().contains(lower) ?? false) ||
            $0.keywords.contains(where: { $0.lowercased().contains(lower) })
        }
    }
    
    func executeSelected() {
        let items = filteredActions
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let action = items[selectedIndex]
        Task {
            await action.action()
        }
    }
}

struct CommandPaletteView: View {
    @StateObject private var viewModel: CommandPaletteViewModel
    @State private var keyMonitor: Any? = nil
    
    init() {
        _viewModel = StateObject(wrappedValue: CommandPaletteViewModel(pluginManager: AppState.shared.pluginManager))
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                
                TextField("Type a command or search…", text: $viewModel.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .onSubmit {
                        viewModel.executeSelected()
                        dismissCommandPalette()
                    }
                
                if !viewModel.query.isEmpty {
                    Button(action: {
                        viewModel.query = ""
                        viewModel.selectedIndex = 0
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: {
                    dismissCommandPalette()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Close Palette (Esc)")
            }
            .padding(16)
            .background(.ultraThinMaterial)
            
            Divider()
            
            // Action List
            ScrollViewReader { proxy in
                List(Array(viewModel.filteredActions.enumerated()), id: \.element.id) { index, action in
                    HStack(spacing: 12) {
                        let isSelected = index == viewModel.selectedIndex
                        
                        Image(systemName: action.icon)
                            .font(.system(size: 16))
                            .frame(width: 24)
                            .foregroundStyle(.blue)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                            
                            if let sub = action.subtitle {
                                Text(sub)
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Text(action.category)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(isSelected ? Color.white.opacity(0.3) : Color.black.opacity(0.2))
                            .clipShape(Capsule())
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .listRowBackground(index == viewModel.selectedIndex ? Color.blue.opacity(0.8) : Color.clear)
                    .onTapGesture {
                        Task {
                            await action.action()
                            dismissCommandPalette()
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: viewModel.selectedIndex) { newIndex in
                    let items = viewModel.filteredActions
                    guard newIndex >= 0 && newIndex < items.count else { return }
                    withAnimation {
                        proxy.scrollTo(items[newIndex].id, anchor: .center)
                    }
                }
                .onChange(of: viewModel.query) { _ in
                    viewModel.selectedIndex = 0
                }
            }
        }
        .frame(width: 600, height: 400)
        .background(VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            viewModel.loadActions()
            
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let count = viewModel.filteredActions.count
                if count == 0 { return event }
                
                // Down arrow
                if event.keyCode == 125 {
                    viewModel.selectedIndex = (viewModel.selectedIndex + 1) % count
                    return nil
                }
                // Up arrow
                if event.keyCode == 126 {
                    viewModel.selectedIndex = (viewModel.selectedIndex - 1 + count) % count
                    return nil
                }
                // Escape
                if event.keyCode == 53 {
                    dismissCommandPalette()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
}
