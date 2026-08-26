import AppKit
import SwiftUI
import Combine
import UserNotifications

/// AppDelegate handles system-level lifecycle events, login item registration,
/// and coordination of background services.
final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var connectionManager: ConnectionManager?
    private var pluginManager: PluginManager?
    private var connectionWatchdog: ConnectionWatchdog?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set Notification Center delegate and register media actions
        UNUserNotificationCenter.current().delegate = self
        let openAction = UNNotificationAction(identifier: "OPEN_ACTION", title: "Open", options: [.foreground])
        let revealAction = UNNotificationAction(identifier: "REVEAL_IN_FINDER_ACTION", title: "Show in Finder", options: [.foreground])
        let mediaCategory = UNNotificationCategory(identifier: "MEDIA_SAVED", actions: [openAction, revealAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var cats = existing
            cats.insert(mediaCategory)
            UNUserNotificationCenter.current().setNotificationCategories(cats)
        }
        
        // Initialize structured logging and window frame diagnostics swizzling
        LinkOSLogger.shared.info("LinkOS starting up", category: .app)
        NSWindow.swizzleDiagnostics()
        
        let bundleID = Bundle.main.bundleIdentifier ?? "UNKNOWN"
        let execPath = Bundle.main.executableURL?.path ?? "UNKNOWN"
        let trustedBefore = AXIsProcessTrusted()
        
        LinkOSLogger.shared.info("""
        === PERMISSION FLOW EMPIRICAL DIAGNOSTIC ===
        - Bundle Identifier: \(bundleID)
        - Executable Path: \(execPath)
        - Initial AXIsProcessTrusted(): \(trustedBefore)
        ============================================
        """, category: .security)
        
        // Initialize core services
        Task { @MainActor in
            PermissionManager.shared.checkPermissionsSilentlyOnLaunch()
            await initializeCoreServices()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        LinkOSLogger.shared.info("LinkOS shutting down", category: .app)
        
        // Stop watchdog before tearing down services
        connectionWatchdog?.stopMonitoring()
        connectionWatchdog = nil
        
        let semaphore = DispatchSemaphore(value: 0)
        
        // Graceful shutdown
        Task {
            await connectionManager?.disconnectAll()
            await pluginManager?.deactivateAll()
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 1.0)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app — don't quit when windows close
        return false
    }
    
    // MARK: - Private
    
    @MainActor
    private func initializeCoreServices() async {
        let appState = AppState.shared
        
        // 1. Initialize plugin manager
        let pluginManager = PluginManager()
        self.pluginManager = pluginManager
        appState.pluginManager = pluginManager
        appState.messageRouter = MessageRouter(pluginManager: pluginManager)
        
        // 2. Initialize connection manager (Bonjour + WebSocket)
        let connectionManager = ConnectionManager()
        self.connectionManager = connectionManager
        appState.connectionManager = connectionManager
        
        // 3. Start Bonjour service advertisement
        let bonjourService = BonjourService()
        appState.bonjourService = bonjourService
        await bonjourService.startAdvertising()
        
        // 4. Start WebSocket server
        await connectionManager.startServer()
        
        // 5. Start ConnectionWatchdog to monitor networking health
        let watchdog = ConnectionWatchdog(webSocketServer: WebSocketServer.shared, bonjourService: bonjourService)
        self.connectionWatchdog = watchdog
        watchdog.startMonitoring()
        
        // 6. Register built-in plugins
        await pluginManager.registerBuiltInPlugins(connectionManager: connectionManager)
        
        // 7. Initialize Continuity Ecosystem singleton services
        _ = AudioSyncService.shared
        _ = CameraReceiverService.shared
        _ = HandoffService.shared
        _ = MediaControlService.shared
        _ = AppLauncherService.shared
        _ = SystemControlService.shared
        _ = AutomationEngine.shared
        
        // 8. Native Silent Permission Verification (No repeated popups)
        PermissionManager.shared.checkPermissionsSilentlyOnLaunch()
        
        // 9. Set up Native Status Item Popover
        setupStatusItem()
        
        LinkOSLogger.shared.info("Core services initialized", category: .app)
    }
    
    // MARK: - Native Status Item & Popover Setup
    
    @MainActor
    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash", accessibilityDescription: "LinkOS Status")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        self.statusItem = statusItem
        
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        
        let rootState = AppState.shared
        let view = MenuBarView().environmentObject(rootState)
        popover.contentViewController = NSHostingController(rootView: view)
        self.popover = popover
        
        // Observe AppState.shared.isConnected to update icon dynamically
        AppState.shared.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                self?.updateStatusItemIcon(isConnected: isConnected)
            }
            .store(in: &cancellables)
    }
    
    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    private func updateStatusItemIcon(isConnected: Bool) {
        guard let button = statusItem?.button else { return }
        let imageName = isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
        button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "LinkOS Status")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let dashboardWindow = NSApp.windows.first(where: { $0.title == "LinkOS Ecosystem" }) {
            if dashboardWindow.isMiniaturized {
                dashboardWindow.deminiaturize(nil)
            }
            if NSApp.isHidden {
                NSApp.unhide(nil)
            }
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return false
        }
        return true
    }
}

// MARK: - UNUserNotificationCenterDelegate Conformance

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notifId = response.notification.request.identifier
        
        if let path = response.notification.request.content.userInfo["filePath"] as? String {
            if response.actionIdentifier == "REVEAL_IN_FINDER_ACTION" {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                completionHandler()
                return
            } else if response.actionIdentifier == "OPEN_ACTION" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                completionHandler()
                return
            }
        }
        
        var action = "dismiss"
        var replyText: String? = nil
        
        if response.actionIdentifier == "REPLY_ACTION", let textResponse = response as? UNTextInputNotificationResponse {
            action = "reply"
            replyText = textResponse.userText
        } else if response.actionIdentifier == "DISMISS_ACTION" {
            action = "dismiss"
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            action = "open"
        }
        
        Task {
            if let notificationsPlugin = await AppState.shared.pluginManager?.getPlugin(NotificationsPlugin.self) {
                await notificationsPlugin.reportInteraction(id: notifId, action: action, text: replyText)
            }
            completionHandler()
        }
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
