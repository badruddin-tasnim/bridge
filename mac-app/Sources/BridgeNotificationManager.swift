import Foundation
import AppKit
import UserNotifications

public class BridgeNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    public static let shared = BridgeNotificationManager()

    @Published public var activeNotifications: [BridgeNotification] = []
    @Published public var replyDrafts: [String: String] = [:]
    @Published public var isSystemNotificationAllowed: Bool = true

    // Settings
    @Published public var isMirroringEnabled: Bool {
        didSet { UserDefaults.standard.set(isMirroringEnabled, forKey: "bridge_notif_mirroring_enabled") }
    }
    @Published public var isSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(isSoundEnabled, forKey: "bridge_notif_sound_enabled") }
    }
    @Published public var isMacAlertsForwardingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMacAlertsForwardingEnabled, forKey: "bridge_mac_alerts_forwarding")
            if isMacAlertsForwardingEnabled {
                AXNotificationObserver.shared.start()
            } else {
                AXNotificationObserver.shared.stop()
            }
        }
    }

    public var sendPayload: ((_ jsonString: String) -> Void)?

    private override init() {
        self.isMirroringEnabled = UserDefaults.standard.object(forKey: "bridge_notif_mirroring_enabled") as? Bool ?? true
        self.isSoundEnabled = UserDefaults.standard.object(forKey: "bridge_notif_sound_enabled") as? Bool ?? true
        self.isMacAlertsForwardingEnabled = UserDefaults.standard.object(forKey: "bridge_mac_alerts_forwarding") as? Bool ?? true

        super.init()

        setupUNNotificationCenter()
        setupMacNotificationObserver()
    }

    private func setupUNNotificationCenter() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        checkNotificationAuth()
    }

    public func checkNotificationAuth() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let allowed = (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                self.isSystemNotificationAllowed = allowed
                if settings.authorizationStatus == .notDetermined {
                    self.requestAuthorization()
                }
            }
        }
    }

    public func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                self?.isSystemNotificationAllowed = granted
            }
        }
    }

    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setupMacNotificationObserver() {
        AXNotificationObserver.shared.onNotificationCaptured = { [weak self] notif in
            guard let self = self, self.isMacAlertsForwardingEnabled else { return }
            self.sendNotificationToPhone(notif)
        }
        if isMacAlertsForwardingEnabled {
            AXNotificationObserver.shared.start()
        }
    }

    // MARK: - Incoming From Phone

    public func handleIncomingPayload(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch type {
            case "notif_post":
                if let notif = try? JSONDecoder().decode(BridgeNotification.self, from: data) {
                    self.processIncomingNotification(notif)
                }

            case "notif_remove":
                if let id = json["id"] as? String {
                    NSLog("[BridgeNotif] Received notif_remove for id: \(id)")
                    self.removeNotification(id: id)
                }

            case "notif_dismiss":
                if let req = try? JSONDecoder().decode(NotificationDismissRequest.self, from: data),
                   req.target == "mac" {
                    AXNotificationObserver.shared.dismissMacNotification(id: req.id)
                }

            default:
                break
            }
        }
    }

    private func processIncomingNotification(_ notif: BridgeNotification) {
        // Prevent duplicate cards if notification has same ID, or same app+title within 4s, or identical (app, title, text)
        if let existingIdx = activeNotifications.firstIndex(where: {
            $0.id == notif.id ||
            ($0.app?.lowercased() == notif.app?.lowercased() && $0.title == notif.title && $0.text == notif.text) ||
            ($0.app?.lowercased() == notif.app?.lowercased() && $0.title == notif.title && abs(($0.timestamp ?? 0) - (notif.timestamp ?? 0)) < 4000)
        }) {
            let oldNotif = activeNotifications[existingIdx]
            activeNotifications[existingIdx] = notif

            if oldNotif.id != notif.id {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [oldNotif.id])
            }

            // If text/title did not change meaningfully, do not trigger a duplicate system banner
            if oldNotif.title == notif.title && oldNotif.text == notif.text {
                return
            }
        } else {
            activeNotifications.insert(notif, at: 0)
        }

        // Limit memory list
        if activeNotifications.count > 40 {
            activeNotifications.removeLast()
        }

        guard isMirroringEnabled else { return }

        // Deliver native banner
        deliverNativeBanner(notif)
    }

    private func deliverNativeBanner(_ notif: BridgeNotification) {
        let content = UNMutableNotificationContent()
        content.title = notif.app ?? "Phone Notification"
        content.subtitle = notif.title ?? ""
        content.body = notif.text ?? ""
        content.sound = isSoundEnabled ? .default : nil
        content.userInfo = ["notif_id": notif.id]

        var unActions: [UNNotificationAction] = []
        if let actions = notif.actions {
            for action in actions {
                let actionId = "act_\(action.id)"
                if action.hasInput {
                    let textAction = UNTextInputNotificationAction(
                        identifier: actionId,
                        title: action.title,
                        options: [],
                        textInputButtonTitle: "Send",
                        textInputPlaceholder: action.placeholder ?? "Type a reply…"
                    )
                    unActions.append(textAction)
                } else {
                    let btnAction = UNNotificationAction(
                        identifier: actionId,
                        title: action.title,
                        options: []
                    )
                    unActions.append(btnAction)
                }
            }
        }

        let categoryId = "cat_\(notif.id)"
        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: unActions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        content.categoryIdentifier = categoryId

        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var updated = existing
            updated.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(updated)

            let request = UNNotificationRequest(
                identifier: notif.id,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    NSLog("[BridgeNotif] Failed to post banner: \(error.localizedDescription)")
                } else {
                    NSLog("[BridgeNotif] Successfully posted banner for '\(notif.id)' [\(notif.app ?? "")]")
                }
            }
        }
    }

    public func removeNotification(id: String) {
        let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        NSLog("[BridgeNotif] Removing notification: '\(cleanId)'. Active before: \(activeNotifications.count)")
        activeNotifications.removeAll(where: {
            $0.id == cleanId || $0.id.trimmingCharacters(in: .whitespacesAndNewlines) == cleanId
        })
        replyDrafts.removeValue(forKey: cleanId)
        NSLog("[BridgeNotif] Active after: \(activeNotifications.count)")

        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [cleanId])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [cleanId])
        let categoryId = "cat_\(cleanId)"
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var updated = existing
            updated = updated.filter { $0.identifier != categoryId }
            UNUserNotificationCenter.current().setNotificationCategories(updated)
        }
    }

    // MARK: - Actions From Mac (Popover & Banners)

    public func sendReply(id: String, actionId: Int, replyText: String) {
        let req = NotificationActionRequest(id: id, actionId: actionId, replyText: replyText)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            sendPayload?(str)
            NSLog("[BridgeNotif] Sent reply for \(id) (action \(actionId)): \(replyText)")
        }
    }

    public func sendAction(id: String, actionId: Int) {
        let req = NotificationActionRequest(id: id, actionId: actionId)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            sendPayload?(str)
            NSLog("[BridgeNotif] Sent action click for \(id) (action \(actionId))")
        }
    }

    public func dismiss(id: String) {
        removeNotification(id: id)
        let req = NotificationDismissRequest(id: id, target: "android")
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            sendPayload?(str)
            NSLog("[BridgeNotif] Sent dismissal for \(id)")
        }
    }

    public func clearAll() {
        for notif in activeNotifications {
            let req = NotificationDismissRequest(id: notif.id, target: "android")
            if let data = try? JSONEncoder().encode(req),
               let str = String(data: data, encoding: .utf8) {
                sendPayload?(str)
            }
        }
        let ids = activeNotifications.map { $0.id }
        activeNotifications.removeAll()
        replyDrafts.removeAll()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().setNotificationCategories([])
    }

    public func sendNotificationToPhone(_ notif: BridgeNotification) {
        guard let data = try? JSONEncoder().encode(notif),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        json["type"] = "notif_post"
        if let outData = try? JSONSerialization.data(withJSONObject: json),
           let str = String(data: outData, encoding: .utf8) {
            sendPayload?(str)
            NSLog("[BridgeNotif] Dispatched Mac alert to phone: [\(notif.app ?? "Mac")] \(notif.title ?? "")")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let notifId = (response.notification.request.content.userInfo["notif_id"] as? String)
            ?? response.notification.request.identifier

        if response.actionIdentifier == UNNotificationDismissActionIdentifier {
            dismiss(id: notifId)
        } else if response.actionIdentifier.starts(with: "act_") {
            let actionIdxStr = response.actionIdentifier.replacingOccurrences(of: "act_", with: "")
            if let actionIdx = Int(actionIdxStr) {
                let textInput = (response as? UNTextInputNotificationResponse)?.userText
                if let text = textInput, !text.isEmpty {
                    sendReply(id: notifId, actionId: actionIdx, replyText: text)
                } else {
                    sendAction(id: notifId, actionId: actionIdx)
                }
            }
        }

        completionHandler()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
