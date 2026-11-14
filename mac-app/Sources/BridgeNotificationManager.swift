import Foundation
import AppKit
import UserNotifications

public class BridgeNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    public static let shared = BridgeNotificationManager()

    @Published public var activeNotifications: [BridgeNotification] = []
    @Published public var replyDrafts: [String: String] = [:]
    @Published public var isSystemNotificationAllowed: Bool = true

    // Shared Synced Notification Settings (Master + Sub-options)
    private var isApplyingRemoteSettings: Bool = false

    @Published public var isMasterNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMasterNotificationsEnabled, forKey: "bridge_notif_master_enabled")
            updateMacObserverState()
            if !isEffectiveAndroidReceiveEnabled {
                clearLocalNotificationsOnly()
            }
            if !isApplyingRemoteSettings {
                recordLocalSettingsChangeAndSync()
            }
        }
    }

    @Published public var isMirroringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMirroringEnabled, forKey: "bridge_notif_mirroring_enabled")
            if !isEffectiveAndroidReceiveEnabled {
                clearLocalNotificationsOnly()
            }
            if !isApplyingRemoteSettings {
                recordLocalSettingsChangeAndSync()
            }
        }
    }

    @Published public var isMacAlertsForwardingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMacAlertsForwardingEnabled, forKey: "bridge_mac_alerts_forwarding")
            updateMacObserverState()
            if !isApplyingRemoteSettings {
                recordLocalSettingsChangeAndSync()
            }
        }
    }

    // Mac-Only Settings
    @Published public var isSoundEnabled: Bool {
        didSet { UserDefaults.standard.set(isSoundEnabled, forKey: "bridge_notif_sound_enabled") }
    }
    @Published public var replyErrors: [String: String] = [:]
    private var pendingBannerWorkItems: [String: DispatchWorkItem] = [:]

    public var settingsUpdatedAt: Int64 {
        get { Int64(UserDefaults.standard.integer(forKey: "bridge_settings_updated_at")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "bridge_settings_updated_at") }
    }

    public var isEffectiveAndroidReceiveEnabled: Bool {
        isMasterNotificationsEnabled && isMirroringEnabled
    }

    public var isEffectiveMacForwardEnabled: Bool {
        isMasterNotificationsEnabled && isMacAlertsForwardingEnabled
    }

    public var sendPayload: ((_ jsonString: String) -> Void)?

    private override init() {
        self.isMasterNotificationsEnabled = UserDefaults.standard.object(forKey: "bridge_notif_master_enabled") as? Bool ?? true
        self.isMirroringEnabled = UserDefaults.standard.object(forKey: "bridge_notif_mirroring_enabled") as? Bool ?? true
        self.isSoundEnabled = UserDefaults.standard.object(forKey: "bridge_notif_sound_enabled") as? Bool ?? true
        self.isMacAlertsForwardingEnabled = UserDefaults.standard.object(forKey: "bridge_mac_alerts_forwarding") as? Bool ?? true

        super.init()

        setupUNNotificationCenter()
        setupMacNotificationObserver()
    }

    private func updateMacObserverState() {
        if isEffectiveMacForwardEnabled {
            AXNotificationObserver.shared.start()
        } else {
            AXNotificationObserver.shared.stop()
        }
    }

    public func recordLocalSettingsChangeAndSync() {
        settingsUpdatedAt = Int64(Date().timeIntervalSince1970 * 1000)
        broadcastSettingsSync()
    }

    public func buildSettingsSyncJson() -> String? {
        let payload: [String: Any] = [
            "type": "settings_sync",
            "notifMasterEnabled": isMasterNotificationsEnabled,
            "androidNotifEnabled": isMirroringEnabled,
            "macNotifEnabled": isMacAlertsForwardingEnabled,
            "autoAcceptFiles": BridgeFileTransferManager.shared.autoAcceptIncomingFiles,
            "updatedAt": settingsUpdatedAt
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    public func broadcastSettingsSync() {
        if let str = buildSettingsSyncJson() {
            sendPayload?(str)
            NSLog("[BridgeNotif] Broadcasted settings_sync: master=\(isMasterNotificationsEnabled), android=\(isMirroringEnabled), mac=\(isMacAlertsForwardingEnabled)")
        }
    }

    private var hasAppBundleContext: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func setupUNNotificationCenter() {
        guard hasAppBundleContext else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        checkNotificationAuth()
    }

    public func checkNotificationAuth() {
        guard hasAppBundleContext else { return }
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
        guard hasAppBundleContext else { return }
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
        guard hasAppBundleContext else { return }
        AXNotificationObserver.shared.onNotificationCaptured = { [weak self] notif in
            guard let self = self, self.isEffectiveMacForwardEnabled else { return }
            self.sendNotificationToPhone(notif)
        }
        if isEffectiveMacForwardEnabled {
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
            case "settings_sync":
                self.handleIncomingSettingsSync(json: json)

            case "notif_post":
                guard self.isEffectiveAndroidReceiveEnabled else {
                    NSLog("[BridgeNotif] Ignoring incoming phone notification (Android notifications disabled)")
                    return
                }
                if let notif = try? JSONDecoder().decode(BridgeNotification.self, from: data) {
                    self.processIncomingNotification(notif)
                }

            case "notif_remove":
                self.handleIncomingRemove(json: json)

            case "notif_sync":
                if let activeIds = json["activeIds"] as? [String] {
                    self.reconcileActiveIds(activeIds)
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

    private func handleIncomingSettingsSync(json: [String: Any]) {
        let remoteUpdatedAt = (json["updatedAt"] as? NSNumber)?.int64Value ?? 0
        if remoteUpdatedAt > 0 && self.settingsUpdatedAt > remoteUpdatedAt {
            // Our local settings are newer than the remote handshake; push ours back
            broadcastSettingsSync()
            return
        }

        isApplyingRemoteSettings = true
        if remoteUpdatedAt > 0 {
            self.settingsUpdatedAt = remoteUpdatedAt
        }
        if let master = json["notifMasterEnabled"] as? Bool {
            self.isMasterNotificationsEnabled = master
        }
        if let androidEnabled = json["androidNotifEnabled"] as? Bool {
            self.isMirroringEnabled = androidEnabled
        }
        if let macEnabled = json["macNotifEnabled"] as? Bool {
            self.isMacAlertsForwardingEnabled = macEnabled
        }
        if let autoAccept = json["autoAcceptFiles"] as? Bool {
            BridgeFileTransferManager.shared.isApplyingRemoteSettings = true
            BridgeFileTransferManager.shared.autoAcceptIncomingFiles = autoAccept
            BridgeFileTransferManager.shared.isApplyingRemoteSettings = false
        }
        isApplyingRemoteSettings = false
        NSLog("[BridgeNotif] Applied remote settings_sync: master=\(isMasterNotificationsEnabled), android=\(isMirroringEnabled), mac=\(isMacAlertsForwardingEnabled), autoAcceptFiles=\(BridgeFileTransferManager.shared.autoAcceptIncomingFiles)")
    }

    private func normalizeNotifId(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func extractBaseId(_ id: String) -> String {
        let norm = normalizeNotifId(id)
        if let range = norm.range(of: "|msg_") {
            return String(norm[..<range.lowerBound])
        }
        if let range = norm.range(of: "|line_") {
            return String(norm[..<range.lowerBound])
        }
        if let range = norm.range(of: "|upd_") {
            return String(norm[..<range.lowerBound])
        }
        return norm
    }

    private func processIncomingNotification(_ rawNotif: BridgeNotification) {
        guard isEffectiveAndroidReceiveEnabled else { return }
        let normalizedId = normalizeNotifId(rawNotif.id)
        guard !normalizedId.isEmpty && normalizedId.count <= 256 else { return }

        let safeIcon = (rawNotif.icon?.count ?? 0) <= 524_288 ? rawNotif.icon : nil
        let safeActions = rawNotif.actions.map { Array($0.prefix(5)) }
        let notif = BridgeNotification(
            id: normalizedId,
            source: rawNotif.source ?? "android",
            pkg: rawNotif.pkg.map { String($0.prefix(128)) },
            app: rawNotif.app.map { String($0.prefix(128)) },
            title: rawNotif.title.map { String($0.prefix(256)) },
            text: rawNotif.text.map { String($0.prefix(4000)) },
            icon: safeIcon,
            timestamp: rawNotif.timestamp,
            actions: safeActions,
            isSilent: rawNotif.isSilent,
            messages: rawNotif.messages,
            isNewestFirst: rawNotif.isNewestFirst
        )

        var previousNotif: BridgeNotification? = nil

        // Only treat as duplicate if ID is identical, or if app, title, AND text match within 2.5s
        if let existingIdx = activeNotifications.firstIndex(where: {
            normalizeNotifId($0.id) == normalizedId ||
            ($0.app?.lowercased() == notif.app?.lowercased() &&
             $0.title == notif.title &&
             $0.text == notif.text &&
             abs(($0.timestamp ?? 0) - (notif.timestamp ?? 0)) < 2500)
        }) {
            let oldNotif = activeNotifications[existingIdx]
            previousNotif = oldNotif
            activeNotifications.remove(at: existingIdx)
            activeNotifications.insert(notif, at: 0)

            // If text, title, and message count/timestamp did not change, do not re-alert
            if oldNotif.title == notif.title &&
               oldNotif.text == notif.text &&
               oldNotif.messages?.count == notif.messages?.count &&
               oldNotif.messages?.last?.timestamp == notif.messages?.last?.timestamp {
                return
            }
        } else {
            activeNotifications.insert(notif, at: 0)
        }

        // Limit memory list
        if activeNotifications.count > 60 {
            activeNotifications.removeLast()
        }

        // Deliver native banner (unless silent sync)
        if !(notif.isSilent ?? false) {
            deliverNativeBanner(notif, previousNotif: previousNotif)
        }
    }

    private static func isLikelyReverseChronologicalApp(_ pkg: String?) -> Bool {
        guard let lower = pkg?.lowercased(), !lower.isEmpty else { return false }
        let emailHints = ["com.google.android.gm", "outlook", "yahoo", "protonmail", "spark", ".email", ".mail"]
        return emailHints.contains(where: { lower.contains($0) })
    }

    public static func formatBannerContent(
        for notif: BridgeNotification,
        previousNotif: BridgeNotification? = nil
    ) -> (subtitle: String, body: String) {
        let baseTitle = notif.title ?? ""

        guard let msgList = notif.messages, !msgList.isEmpty else {
            return (baseTitle, notif.text ?? "")
        }

        if msgList.count == 1 {
            let single = msgList[0]
            let body: String
            if let sender = single.sender, !sender.isEmpty, sender != notif.title {
                body = "\(sender): \(single.text)"
            } else {
                body = !single.text.isEmpty ? single.text : (notif.text ?? "")
            }
            return (baseTitle, String(body.prefix(2000)))
        }

        // Determine whether message array is already newest-first or chronological (oldest-first).
        let alreadyNewestFirst: Bool
        if let explicit = notif.isNewestFirst {
            alreadyNewestFirst = explicit
        } else if let prevMsgs = previousNotif?.messages, !prevMsgs.isEmpty {
            if msgList.last?.text != prevMsgs.last?.text && msgList.first?.text == prevMsgs.first?.text {
                alreadyNewestFirst = false
            } else if msgList.first?.text != prevMsgs.first?.text && msgList.last?.text == prevMsgs.last?.text {
                alreadyNewestFirst = true
            } else if (msgList.first?.timestamp ?? 0) < (msgList.last?.timestamp ?? 0) {
                alreadyNewestFirst = false
            } else {
                alreadyNewestFirst = isLikelyReverseChronologicalApp(notif.pkg)
            }
        } else if (msgList.first?.timestamp ?? 0) < (msgList.last?.timestamp ?? 0) {
            alreadyNewestFirst = false
        } else {
            alreadyNewestFirst = isLikelyReverseChronologicalApp(notif.pkg)
        }

        // Put the newest messages at the top so collapsed macOS banners always preview the latest message,
        // while expanding the notification reveals all older stacked messages underneath.
        let ordered = alreadyNewestFirst ? msgList : Array(msgList.reversed())
        let formattedLines = ordered.map { msg -> String in
            if let sender = msg.sender, !sender.isEmpty, sender != notif.title {
                return "\(sender): \(msg.text)"
            }
            return msg.text
        }

        let subtitle: String
        if !baseTitle.isEmpty && !baseTitle.localizedCaseInsensitiveContains("message") {
            subtitle = "\(baseTitle) · \(msgList.count) messages"
        } else {
            subtitle = baseTitle
        }

        let joined = formattedLines.joined(separator: "\n")
        return (subtitle, String(joined.prefix(2000)))
    }

    private func deliverNativeBanner(_ notif: BridgeNotification, previousNotif: BridgeNotification? = nil) {
        pendingBannerWorkItems[notif.id]?.cancel()
        pendingBannerWorkItems.removeValue(forKey: notif.id)

        let formatted = Self.formatBannerContent(for: notif, previousNotif: previousNotif)

        let content = UNMutableNotificationContent()
        content.title = notif.app ?? "Phone Notification"
        content.subtitle = formatted.subtitle
        content.body = formatted.body
        content.sound = isSoundEnabled ? .default : nil
        content.threadIdentifier = extractBaseId(notif.id)
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

        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { [weak self] existing in
            var updated = existing
            updated.update(with: category)
            center.setNotificationCategories(updated)

            center.getDeliveredNotifications { delivered in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard self.activeNotifications.contains(where: { self.normalizeNotifId($0.id) == notif.id }) else {
                        return
                    }

                    let request = UNNotificationRequest(
                        identifier: notif.id,
                        content: content,
                        trigger: nil
                    )
                    let postRequest: () -> Void = {
                        center.add(request) { error in
                            if let error = error {
                                NSLog("[BridgeNotif] Failed to post banner: \(error.localizedDescription)")
                            } else {
                                NSLog("[BridgeNotif] Successfully posted banner for '\(notif.id)' [\(notif.app ?? "")]")
                            }
                        }
                    }

                    let alreadyDelivered = delivered.contains { $0.request.identifier == notif.id }
                    if alreadyDelivered {
                        self.pendingBannerWorkItems[notif.id]?.cancel()
                        center.removeDeliveredNotifications(withIdentifiers: [notif.id])
                        let workItem = DispatchWorkItem { [weak self] in
                            guard let self = self else { return }
                            self.pendingBannerWorkItems.removeValue(forKey: notif.id)
                            guard self.activeNotifications.contains(where: { self.normalizeNotifId($0.id) == notif.id }) else {
                                return
                            }
                            postRequest()
                        }
                        self.pendingBannerWorkItems[notif.id] = workItem
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
                    } else {
                        postRequest()
                    }
                }
            }
        }
    }

    private func handleIncomingRemove(json: [String: Any]) {
        let rawId = (json["id"] as? String) ?? ""
        let cleanId = normalizeNotifId(rawId)
        let baseTarget = extractBaseId(cleanId)
        let pkg = (json["pkg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var removedIds = Set<String>()
        if !cleanId.isEmpty {
            removedIds.insert(cleanId)
        }
        if !baseTarget.isEmpty {
            removedIds.insert(baseTarget)
        }

        for existing in activeNotifications {
            let existingNorm = normalizeNotifId(existing.id)
            let existingBase = extractBaseId(existingNorm)
            if existingNorm == cleanId || existingBase == baseTarget || (!baseTarget.isEmpty && existingNorm.hasPrefix("\(baseTarget)|")) {
                removedIds.insert(existing.id)
                continue
            }
            if !pkg.isEmpty && existing.pkg == pkg {
                let existingTitle = (existing.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let existingText = (existing.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty && existingTitle == title && (text.isEmpty || existingText == text) {
                    removedIds.insert(existing.id)
                }
            }
        }

        for rId in removedIds {
            removeNotification(id: rId)
        }

        // Reconcile against authoritative activeIds snapshot from phone if provided
        if let activeIds = json["activeIds"] as? [String] {
            reconcileActiveIds(activeIds)
        }
    }

    public func reconcileActiveIds(_ rawActiveIds: [String]) {
        let activeBaseSet = Set(rawActiveIds.map { extractBaseId(normalizeNotifId($0)) })
        let activeExactSet = Set(rawActiveIds.map { normalizeNotifId($0) })

        let staleIds = activeNotifications
            .filter { notif in
                guard notif.source == nil || notif.source == "android" else { return false }
                let normId = normalizeNotifId(notif.id)
                let baseId = extractBaseId(normId)
                return !activeBaseSet.contains(baseId) && !activeExactSet.contains(normId)
            }
            .map { $0.id }

        for staleId in staleIds {
            NSLog("[BridgeNotif] Reconciling & removing cleared phone notification: '\(staleId)'")
            removeNotification(id: staleId)
        }
    }

    public func removeNotification(id: String) {
        let cleanId = normalizeNotifId(id)
        NSLog("[BridgeNotif] Removing notification: '\(cleanId)'. Active before: \(activeNotifications.count)")
        let matchingIds = activeNotifications
            .filter { $0.id == id || normalizeNotifId($0.id) == cleanId }
            .map { $0.id }
        activeNotifications.removeAll(where: {
            $0.id == id || normalizeNotifId($0.id) == cleanId
        })
        let allIdsToClean = Array(Set(matchingIds + [id, cleanId]))
        for key in allIdsToClean {
            pendingBannerWorkItems[key]?.cancel()
            pendingBannerWorkItems.removeValue(forKey: key)
            replyDrafts.removeValue(forKey: key)
            replyErrors.removeValue(forKey: key)
        }
        NSLog("[BridgeNotif] Active after: \(activeNotifications.count)")

        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: allIdsToClean)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: allIdsToClean)
        let categoryIds = Set(allIdsToClean.map { "cat_\($0)" })
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            let updated = existing.filter { !categoryIds.contains($0.identifier) }
            UNUserNotificationCenter.current().setNotificationCategories(updated)
        }
    }

    // MARK: - Actions From Mac (Popover & Banners)

    public func sendReply(id: String, actionId: Int, replyText: String) {
        let baseId = extractBaseId(id)
        guard let sendPayload = sendPayload else {
            replyErrors[id] = "Failed to send. Phone is disconnected."
            return
        }
        let req = NotificationActionRequest(id: baseId, actionId: actionId, replyText: replyText)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            sendPayload(str)
            replyErrors.removeValue(forKey: id)
            replyErrors.removeValue(forKey: baseId)
            NSLog("[BridgeNotif] Sent reply for \(baseId) (action \(actionId)): \(replyText)")
        } else {
            replyErrors[id] = "Could not encode reply."
        }
    }

    public func sendAction(id: String, actionId: Int) {
        let baseId = extractBaseId(id)
        let req = NotificationActionRequest(id: baseId, actionId: actionId)
        if let data = try? JSONEncoder().encode(req),
           let str = String(data: data, encoding: .utf8) {
            sendPayload?(str)
            NSLog("[BridgeNotif] Sent action click for \(baseId) (action \(actionId))")
        }
    }

    public func dismiss(id: String) {
        let cleanId = normalizeNotifId(id)
        let baseId = extractBaseId(cleanId)
        removeNotification(id: id)

        // Only send dismissal to Android if no remaining notifications share this baseId
        let hasRemainingForBase = activeNotifications.contains {
            extractBaseId(normalizeNotifId($0.id)) == baseId
        }

        if !hasRemainingForBase {
            let req = NotificationDismissRequest(id: baseId, target: "android")
            if let data = try? JSONEncoder().encode(req),
               let str = String(data: data, encoding: .utf8) {
                sendPayload?(str)
                NSLog("[BridgeNotif] Sent dismissal for base notification \(baseId)")
            }
        }
    }

    public func clearLocalNotificationsOnly() {
        for (_, item) in pendingBannerWorkItems {
            item.cancel()
        }
        pendingBannerWorkItems.removeAll()
        let ids = activeNotifications.map { $0.id }
        activeNotifications.removeAll()
        replyDrafts.removeAll()
        replyErrors.removeAll()
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.getNotificationCategories { existing in
            let preserved = existing.filter { $0.identifier.hasPrefix("cat_file_") }
            center.setNotificationCategories(preserved)
        }
    }

    public func clearAll() {
        var dismissedBaseIds = Set<String>()
        for notif in activeNotifications {
            let baseId = extractBaseId(notif.id)
            if !dismissedBaseIds.contains(baseId) {
                dismissedBaseIds.insert(baseId)
                let req = NotificationDismissRequest(id: baseId, target: "android")
                if let data = try? JSONEncoder().encode(req),
                   let str = String(data: data, encoding: .utf8) {
                    sendPayload?(str)
                }
            }
        }
        clearLocalNotificationsOnly()
    }

    public func sendNotificationToPhone(_ notif: BridgeNotification) {
        guard isEffectiveMacForwardEnabled else { return }
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
        let reqId = response.notification.request.identifier
        if reqId.starts(with: "bridge.transfer.") {
            let transferId = (response.notification.request.content.userInfo["transfer_id"] as? String)
                ?? reqId.replacingOccurrences(of: "bridge.transfer.", with: "")
            if response.actionIdentifier.starts(with: "file_accept_") {
                if let item = BridgeFileTransferManager.shared.transfers.first(where: { $0.id == transferId }) {
                    BridgeFileTransferManager.shared.acceptIncomingTransfer(item)
                }
            } else if response.actionIdentifier.starts(with: "file_decline_") || response.actionIdentifier == UNNotificationDismissActionIdentifier {
                BridgeFileTransferManager.shared.cancelTransfer(id: transferId, notifyPeer: true)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            completionHandler()
            return
        }

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
