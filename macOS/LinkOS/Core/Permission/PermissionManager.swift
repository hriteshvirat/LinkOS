import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit
import IOKit.hid
import UserNotifications
import ScreenCaptureKit

public enum SystemPermissionType: String, CaseIterable, Identifiable {
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"
    case notifications = "Notifications"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .screenRecording: return "display"
        case .accessibility: return "hand.tap"
        case .notifications: return "bell"
        }
    }
    
    public var usageDescription: String {
        switch self {
        case .screenRecording: return "Required for Remote Desktop screen streaming to your paired Android device."
        case .accessibility: return "Required for wireless Trackpad gestures and keyboard input simulation."
        case .notifications: return "Required to display incoming pairing requests and file transfer alerts."
        }
    }
}

public enum PermissionStatus: String, CaseIterable, Identifiable {
    case authorized = "Authorized 🟢"
    case grantedRestartRequired = "Granted (Restart Required) 🟡"
    case actionRequired = "Action Required 🟠"
    case denied = "Denied 🔴"
    
    public var id: String { rawValue }
}

@MainActor
public enum PermissionState: String, Codable {
    case unknown
    case checking
    case granted
    case denied
    case requesting
    case waitingForSystem
}

/// Centralized Native macOS Permission Manager — single source of truth for all system permissions.
/// Performs silent status preflights, exposes simple query APIs, and auto-refreshes in real-time when returning focus to LinkOS.
@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public var isAccessibilityGranted: Bool = false
    @Published public var isScreenRecordingGranted: Bool = false
    @Published public var isNotificationsGranted: Bool = false
    
    @Published public var accessibilityStatus: PermissionStatus = .actionRequired
    @Published public var screenRecordingStatus: PermissionStatus = .actionRequired
    @Published public var notificationsStatus: PermissionStatus = .actionRequired
    
    @Published public var screenRecordingState: PermissionState = .unknown
    @Published public var accessibilityState: PermissionState = .unknown
    
    private var isNotificationChecking: Bool = false
    
    // Debounce / Concurrency guards
    private var isRequestingScreenRecording: Bool = false
    private var isRequestingAccessibility: Bool = false
    private var isRequestingNotifications: Bool = false
    
    private var focusObserver: NSObjectProtocol?
    /// Prevents repeated permission checks on rapid Cmd-Tab / window switches.
    /// Permissions are only re-evaluated if at least 30 seconds have passed since the last check.
    private var lastRefreshTime: Date = .distantPast
    private let refreshCooldown: TimeInterval = 30
    
    private init() {
        // Read screen recording state from UserDefaults
        if let savedStateStr = UserDefaults.standard.string(forKey: "linkos_screen_recording_state"),
           let savedState = PermissionState(rawValue: savedStateStr) {
            self.screenRecordingState = savedState
        } else {
            self.screenRecordingState = .unknown
        }
        
        // Perform initial silent status query
        refreshPermissionStates()
        
        // Auto-refresh permission status when user returns to the app from System Settings.
        // Debounced to at most once per 30 seconds to avoid log spam on every Cmd-Tab.
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let now = Date()
                guard now.timeIntervalSince(self.lastRefreshTime) >= self.refreshCooldown else {
                    LinkOSLogger.shared.debug("[PermissionManager] didBecomeActive: skipping refresh (cooldown active)", category: .security)
                    return
                }
                self.refreshPermissionStates()
            }
        }
    }
    
    // MARK: - Lifecycle
    
    deinit {
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func updateScreenRecordingState(_ newState: PermissionState) {
        if self.screenRecordingState != newState {
            LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] Transitioning from \(self.screenRecordingState.rawValue) to \(newState.rawValue)", category: .security)
            self.screenRecordingState = newState
            UserDefaults.standard.set(newState.rawValue, forKey: "linkos_screen_recording_state")
        }
    }

    private func updateAccessibilityState(_ newState: PermissionState) {
        if self.accessibilityState != newState {
            LinkOSLogger.shared.info("[PermissionManager] [Accessibility] Transitioning from \(self.accessibilityState.rawValue) to \(newState.rawValue)", category: .security)
            self.accessibilityState = newState
        }
    }
    
    public func checkScreenRecordingPermissionSilent() -> Bool {
        if #available(macOS 11.0, *) {
            return CGPreflightScreenCaptureAccess()
        } else {
            return true
        }
    }
    
    /// Silently queries current native permission states on the Main thread without blocking UI.
    public func refreshPermissionStates() {
        lastRefreshTime = Date()
        updateAccessibilityState(.checking)
        let accessibility = AXIsProcessTrusted()
        
        if self.isAccessibilityGranted != accessibility {
            self.isAccessibilityGranted = accessibility
            self.accessibilityStatus = accessibility ? .authorized : .actionRequired
            LinkOSLogger.shared.info("[PermissionManager] [Accessibility] State updated to \(accessibility ? "Granted" : "Denied")", category: .security)
            LinkOSLogger.shared.info("[PermissionManager] [Accessibility] UI Updated", category: .security)
        }
        updateAccessibilityState(accessibility ? .granted : .denied)
        
        updateScreenRecordingState(.checking)
        let screenRecording = checkScreenRecordingPermissionSilent()
        
        if screenRecording {
            if self.screenRecordingState != .granted {
                updateScreenRecordingState(.granted)
            }
            if !self.isScreenRecordingGranted {
                self.isScreenRecordingGranted = true
                self.screenRecordingStatus = .authorized
                LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] State updated to Granted", category: .security)
                LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] UI Updated", category: .security)
                NotificationCenter.default.post(name: NSNotification.Name("LinkOSScreenRecordingGranted"), object: nil)
            }
        } else {
            if self.isScreenRecordingGranted {
                self.isScreenRecordingGranted = false
                self.screenRecordingStatus = .actionRequired
                LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] State updated to Denied", category: .security)
                LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] UI Updated", category: .security)
            }
            
            // If it was granted, but now it is false, the user revoked it in settings!
            if self.screenRecordingState == .granted {
                updateScreenRecordingState(.denied)
            } else {
                updateScreenRecordingState(.denied)
            }
        }
        
        // Polling removed in favor of event-based caching.
        
        if NSClassFromString("XCTest") == nil {
            guard !isNotificationChecking else { return }
            isNotificationChecking = true
            
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let notifications = (settings.authorizationStatus == .authorized)
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.isNotificationsGranted != notifications {
                        self.isNotificationsGranted = notifications
                        self.notificationsStatus = notifications ? .authorized : .actionRequired
                        LinkOSLogger.shared.info("[PermissionManager] [Notifications] State updated to \(notifications ? "Granted" : "Denied")", category: .security)
                        LinkOSLogger.shared.info("[PermissionManager] [Notifications] UI Updated", category: .security)
                    }
                    self.isNotificationChecking = false
                }
            }
        }
    }
    
    /// Checks permissions silently on launch without showing dialogs or popups.
    public func checkPermissionsSilentlyOnLaunch() {
        LinkOSLogger.shared.info("[PermissionManager] Silent startup flow initiated. Reading macOS permission states.", category: .security)
        refreshPermissionStates()
    }
    
    /// Returns current authorization status for a specific permission.
    public func hasPermission(_ type: SystemPermissionType) -> Bool {
        switch type {
        case .screenRecording: return checkScreenRecordingPermissionSilent()
        case .accessibility: return AXIsProcessTrusted()
        case .notifications: return isNotificationsGranted
        }
    }
    
    /// Returns detailed status enum for a specific permission.
    public func status(for type: SystemPermissionType) -> PermissionStatus {
        switch type {
        case .screenRecording:
            return checkScreenRecordingPermissionSilent() ? .authorized : .actionRequired
        case .accessibility: return AXIsProcessTrusted() ? .authorized : .actionRequired
        case .notifications: return notificationsStatus
        }
    }
    
    /// Dedicated explicit request helper — called exclusively when the user interacts with a feature requiring authorization.
    public func requestPermissionExplicitly(_ permission: SystemPermissionType) {
        switch permission {
        case .screenRecording:
            // Idempotency Check
            if checkScreenRecordingPermissionSilent() {
                updateScreenRecordingState(.granted)
                refreshPermissionStates()
                LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] Request ignored: already granted.", category: .security)
                return
            }
            
            // Debounce Guard
            guard !isRequestingScreenRecording else {
                LinkOSLogger.shared.info("[PermissionManager] [ScreenRecording] Request debounced: already in flight.", category: .security)
                return 
            }
            isRequestingScreenRecording = true
            updateScreenRecordingState(.requesting)
            
            if self.screenRecordingState == .denied || self.screenRecordingState == .waitingForSystem {
                updateScreenRecordingState(.waitingForSystem)
                openSystemSettings(for: .screenRecording)

            } else {
                updateScreenRecordingState(.waitingForSystem)
                if #available(macOS 11.0, *) {
                    // Triggers the system authorization prompt
                    let granted = CGRequestScreenCaptureAccess()
                    if granted {
                        updateScreenRecordingState(.granted)
                        self.isScreenRecordingGranted = true
                        self.screenRecordingStatus = .authorized
                        NotificationCenter.default.post(name: NSNotification.Name("LinkOSScreenRecordingGranted"), object: nil)

                    } else {
                        updateScreenRecordingState(.denied)
                    }
                } else {
                    updateScreenRecordingState(.granted)

                }
            }
            isRequestingScreenRecording = false
            
        case .accessibility:
            // Idempotency Check
            if AXIsProcessTrusted() {
                LinkOSLogger.shared.info("[PermissionManager] [Accessibility] Request ignored: already granted.", category: .security)
                updateAccessibilityState(.granted)
                refreshPermissionStates()
                return
            }
            
            // Debounce Guard
            guard !isRequestingAccessibility else {
                LinkOSLogger.shared.info("[PermissionManager] [Accessibility] Request debounced: already in flight.", category: .security)
                return
            }
            isRequestingAccessibility = true
            updateAccessibilityState(.requesting)
            
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            
            if trusted {
                updateAccessibilityState(.granted)
                self.isAccessibilityGranted = true
                self.accessibilityStatus = .authorized
            } else {
                updateAccessibilityState(.waitingForSystem)
                openSystemSettings(for: .accessibility)

            }
            
            isRequestingAccessibility = false
            
        case .notifications:
            // Debounce Guard
            guard !isRequestingNotifications else { return }
            isRequestingNotifications = true
            
            if NSClassFromString("XCTest") == nil {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                    Task { @MainActor [weak self] in
                        self?.refreshPermissionStates()
                        self?.isRequestingNotifications = false
                    }
                }
            } else {
                self.isRequestingNotifications = false
            }
            openSystemSettings(for: .notifications)
        }
        
        refreshPermissionStates()
    }
    
    /// Opens macOS System Settings directly to the specified privacy pane.
    public func openSystemSettings(for permission: SystemPermissionType) {
        let urlString: String
        switch permission {
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        }
        
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Smoothly quits and relaunches LinkOS to refresh process TCC token cache.
    public func relaunchApp() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
