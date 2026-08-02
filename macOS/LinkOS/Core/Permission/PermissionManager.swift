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

/// Centralized Native macOS Permission Manager — single source of truth for all system permissions.
/// Performs silent status preflights, exposes simple query APIs, and auto-refreshes in real-time when returning focus to LinkOS.
@MainActor
public enum ScreenRecordingPermissionState: String, Codable {
    case unknown
    case notRequested
    case requesting
    case granted
    case denied
    case waitingForUserAction
}

@MainActor
public final class PermissionManager: ObservableObject {
    public static let shared = PermissionManager()
    
    @Published public var isAccessibilityGranted: Bool = false
    @Published public var isScreenRecordingGranted: Bool = false
    @Published public var isNotificationsGranted: Bool = false
    
    @Published public var accessibilityStatus: PermissionStatus = .actionRequired
    @Published public var screenRecordingStatus: PermissionStatus = .actionRequired
    @Published public var notificationsStatus: PermissionStatus = .actionRequired
    
    @Published public var screenRecordingState: ScreenRecordingPermissionState = .unknown
    
    private var isNotificationChecking: Bool = false
    private var isRequestingScreenRecording: Bool = false
    private var focusObserver: NSObjectProtocol?
    private var pollingTimer: Timer?
    
    private init() {
        // Read screen recording state from UserDefaults
        if let savedStateStr = UserDefaults.standard.string(forKey: "linkos_screen_recording_state"),
           let savedState = ScreenRecordingPermissionState(rawValue: savedStateStr) {
            self.screenRecordingState = savedState
        } else {
            self.screenRecordingState = .notRequested
        }
        
        // Perform initial silent status query
        refreshPermissionStates()
        
        // Start live 500ms auto-refresh timer for real-time permission status updates
        startPermissionPolling()
        
        // Auto-refresh permission status immediately when user switches back from macOS System Settings to LinkOS
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStates()
            }
        }
    }
    
    private func startPermissionPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStates()
            }
        }
    }
    
    deinit {
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func updateScreenRecordingState(_ newState: ScreenRecordingPermissionState) {
        self.screenRecordingState = newState
        UserDefaults.standard.set(newState.rawValue, forKey: "linkos_screen_recording_state")
        LinkOSLogger.shared.info("[PermissionManager] Screen Recording state transitioned to: \(newState.rawValue)", category: .security)
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
        let accessibility = AXIsProcessTrusted()
        
        if self.isAccessibilityGranted != accessibility {
            self.isAccessibilityGranted = accessibility
            self.accessibilityStatus = accessibility ? .authorized : .actionRequired
            LinkOSLogger.shared.info("[PermissionManager Status Update] Accessibility: \(accessibility)", category: .security)
        }
        
        let screenRecording = checkScreenRecordingPermissionSilent()
        
        if screenRecording {
            if self.screenRecordingState != .granted {
                updateScreenRecordingState(.granted)
            }
            if !self.isScreenRecordingGranted {
                self.isScreenRecordingGranted = true
                self.screenRecordingStatus = .authorized
                LinkOSLogger.shared.info("[PermissionManager Status Update] Screen Recording (Silent check): true", category: .security)
                NotificationCenter.default.post(name: NSNotification.Name("LinkOSScreenRecordingGranted"), object: nil)
            }
        } else {
            if self.isScreenRecordingGranted {
                self.isScreenRecordingGranted = false
                self.screenRecordingStatus = .actionRequired
                LinkOSLogger.shared.info("[PermissionManager Status Update] Screen Recording (Silent check): false", category: .security)
            }
            
            // If it was granted, but now it is false, the user revoked it in settings!
            if self.screenRecordingState == .granted {
                updateScreenRecordingState(.denied)
            }
        }
        
        guard !isNotificationChecking else { return }
        isNotificationChecking = true
        
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let notifications = (settings.authorizationStatus == .authorized)
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isNotificationsGranted != notifications {
                    self.isNotificationsGranted = notifications
                    self.notificationsStatus = notifications ? .authorized : .actionRequired
                    LinkOSLogger.shared.info("[PermissionManager Status Update] Notifications: \(notifications)", category: .security)
                }
                self.isNotificationChecking = false
            }
        }
    }
    
    /// Checks permissions silently on launch without showing dialogs or popups.
    public func checkPermissionsSilentlyOnLaunch() {
        refreshPermissionStates()
    }
    
    /// Returns current authorization status for a specific permission.
    public func hasPermission(_ type: SystemPermissionType) -> Bool {
        switch type {
        case .screenRecording:
            return checkScreenRecordingPermissionSilent()
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
            if checkScreenRecordingPermissionSilent() {
                updateScreenRecordingState(.granted)
                refreshPermissionStates()
                return
            }
            
            // Prevent duplicate request overlap
            guard !isRequestingScreenRecording else { return }
            isRequestingScreenRecording = true
            
            if self.screenRecordingState == .denied || self.screenRecordingState == .waitingForUserAction {
                updateScreenRecordingState(.waitingForUserAction)
                openSystemSettings(for: .screenRecording)
            } else {
                updateScreenRecordingState(.requesting)
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
            if AXIsProcessTrusted() {
                LinkOSLogger.shared.info("[PermissionManager] Accessibility already trusted — skipping prompt", category: .security)
                return
            }
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted {
                openSystemSettings(for: .accessibility)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                let trustedAfter = AXIsProcessTrusted()
                LinkOSLogger.shared.info("[PermissionManager] AX trusted after returning (2s delay): \(trustedAfter)", category: .security)
                self?.refreshPermissionStates()
            }
            
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshPermissionStates()
                }
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
