import Cocoa
import SwiftUI
import Combine

enum ToolbarDockState: String, CaseIterable, Equatable, Sendable {
    case floating
    case previewingLeft, previewingRight, previewingBottom, previewingTop
    case dockedLeft, dockedRight, dockedBottom, dockedTop
    
    var isVertical: Bool {
        switch self {
        case .previewingLeft, .previewingRight, .dockedLeft, .dockedRight:
            return true
        default:
            return false
        }
    }
    
    var isHorizontal: Bool { !isVertical }
    
    var isDocked: Bool {
        switch self {
        case .dockedLeft, .dockedRight, .dockedBottom, .dockedTop: return true
        default: return false
        }
    }
    
    var isPreviewing: Bool {
        switch self {
        case .previewingLeft, .previewingRight, .previewingBottom, .previewingTop: return true
        default: return false
        }
    }
    
    var edge: ToolbarEdge? {
        switch self {
        case .previewingLeft, .dockedLeft: return .left
        case .previewingRight, .dockedRight: return .right
        case .previewingBottom, .dockedBottom: return .bottom
        case .previewingTop, .dockedTop: return .top
        case .floating: return nil
        }
    }
    
    static func docked(for edge: ToolbarEdge) -> ToolbarDockState {
        switch edge {
        case .left: return .dockedLeft
        case .right: return .dockedRight
        case .bottom: return .dockedBottom
        case .top: return .dockedTop
        }
    }
    
    static func previewing(for edge: ToolbarEdge) -> ToolbarDockState {
        switch edge {
        case .left: return .previewingLeft
        case .right: return .previewingRight
        case .bottom: return .previewingBottom
        case .top: return .previewingTop
        }
    }
}

@MainActor
final class MirroringWorkspace: ObservableObject {
    static let shared = MirroringWorkspace()
    
    @Published var isCursorInsideWorkspace: Bool = false
    // We track the frames of all active interaction regions
    @Published var phoneWindowFrame: NSRect = .zero
    @Published var toolbarPanelFrame: NSRect = .zero
    
    // UI States
    @Published var dockState: ToolbarDockState = {
        let saved = UserDefaults.standard.string(forKey: "pm_toolbar_edge") ?? ""
        let edge = ToolbarEdge(rawValue: saved) ?? .bottom
        return .docked(for: edge)
    }()
    
    @Published var activeToolbarEdge: ToolbarEdge = {
        let saved = UserDefaults.standard.string(forKey: "pm_toolbar_edge") ?? ""
        return ToolbarEdge(rawValue: saved) ?? .bottom
    }()
    
    @Published var approachingEdge: ToolbarEdge? = nil
    @Published var relativeY: CGFloat = 0.5
    
    
    // Popover UI
    @Published var showControlsPopover: Bool = false
    
    // Developer UI
    @Published var showDevDiagnostics: Bool = false
    
    // Pointer States
    @Published var pointerStyle: String = "default"
    @Published var pointerVisibility: Bool = true
    @Published var pointerSize: CGFloat = 1.0
    
    // Focus States
    @Published var isPhoneFocused: Bool = false
    @Published var isWindowFocused: Bool = false
    @Published var keyboardFocus: Bool = false
    @Published var privacyMode: Bool = false
    
    // App State
    private var isAppActive: Bool = true
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        setupAppObservers()
    }
    
    private func setupAppObservers() {
        let center = NotificationCenter.default
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.isAppActive = false
            }
            .store(in: &cancellables)
            
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.isAppActive = true
            }
            .store(in: &cancellables)
    }
}
