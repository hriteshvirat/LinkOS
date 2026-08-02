import Foundation
import UserNotifications
import AppKit

/// Receives notification mirroring payloads from Android, schedules macOS banner alerts, and routes dismiss/replies.
@MainActor
final class NotificationsPlugin: NSObject, LinkOSPlugin, ConnectionStateSubscriber {
    let pluginId = "notifications"
    let displayName = "Notification Mirror"
    let version = "1.0.0"
    let subscribedChannels: Set<String> = ["notifications"]
    let requiredPermissions: Set<String> = ["NOTIFICATION_READ", "NOTIFICATION_INTERACT"]
    
    var subscriberId = "notifications_plugin"
    private(set) var isActive = false
    private weak var connectionManager: ConnectionManager?
    
    private let logger = LinkOSLogger.shared
    
    init(connectionManager: ConnectionManager? = nil) {
        self.connectionManager = connectionManager
        super.init()
        ConnectionStateManager.shared.subscribe(self)
        registerNotificationCategories()
    }
    
    func activate() async throws {
        isActive = true
        // Request authorization natively
        let center = UNUserNotificationCenter.current()
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
        logger.info("NotificationsPlugin activated and UNUserNotificationCenter authorized", category: .notifications)
    }
    
    func deactivate() async {
        isActive = false
        logger.info("NotificationsPlugin deactivated", category: .notifications)
    }
    
    func handleMessage(_ message: LinkOSMessageEnvelope) async {
        // Fallback for direct message handling
    }
    
    func connectionDidChange(phase: ConnectionPhase, device: PeerDevice?) async {
        if phase == .disconnected {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
    }
    
    func didReceiveMessage(channel: MessageChannel, payload: Data, from deviceId: String) async {
        guard channel == .notifications, isActive else { return }
        
        do {
            if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                let action = json["action"] as? String
                if action == "dismiss" {
                    if let notifId = json["id"] as? String {
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notifId])
                    }
                    return
                }
                
                guard let notifId = json["id"] as? String,
                      let appName = json["app_name"] as? String,
                      let title = json["title"] as? String,
                      let body = json["body"] as? String else { return }
                
                scheduleNativeNotification(id: notifId, appName: appName, title: title, body: body)
            }
        } catch {
            logger.error("Failed to parse mirrored notification envelope: \(error.localizedDescription)", category: .notifications)
        }
    }
    
    func qosDidChange(state: QoSState) async {
        // QoS updates
    }
    
    private func registerNotificationCategories() {
        // Set up interactive category allowing custom quick replies
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type reply..."
        )
        
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: [.destructive]
        )
        
        let category = UNNotificationCategory(
            identifier: "LINKOS_NOTIF_CATEGORY",
            actions: [replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    private func scheduleNativeNotification(id: String, appName: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = appName
        content.subtitle = title
        content.body = body
        content.categoryIdentifier = "LINKOS_NOTIF_CATEGORY"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                self?.logger.error("Failed to schedule UNNotificationRequest: \(error.localizedDescription)", category: .notifications)
            }
        }
    }
    
    /// Reports quick replies or dismissal responses back to Android device.
    func reportInteraction(id: String, action: String, text: String? = nil) async {
        let payload: [String: Any] = [
            "action": action,
            "id": id,
            "reply_text": text ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload), let connectionManager {
            let wrapped = MessageRouter.createEvent(channel: "notifications", payload: data)
            await connectionManager.broadcast(wrapped)
        }
    }
}
