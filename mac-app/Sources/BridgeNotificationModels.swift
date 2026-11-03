import Foundation
import AppKit

// MARK: - Notification Data Models

public struct BridgeNotificationAction: Codable, Identifiable {
    public let id: Int
    public let title: String
    public let hasInput: Bool
    public let placeholder: String?

    public init(id: Int, title: String, hasInput: Bool = false, placeholder: String? = nil) {
        self.id = id
        self.title = title
        self.hasInput = hasInput
        self.placeholder = placeholder
    }
}

public struct BridgeNotification: Codable, Identifiable {
    public let id: String
    public let source: String?       // "android" or "mac"
    public let pkg: String?          // e.g. "com.whatsapp"
    public let app: String?          // e.g. "WhatsApp"
    public let title: String?        // e.g. "Sarah"
    public let text: String?         // e.g. "Are we still meeting at 3?"
    public let icon: String?         // Base64 encoded PNG
    public let timestamp: Int64?     // Epoch ms
    public let actions: [BridgeNotificationAction]?

    public init(
        id: String,
        source: String? = "android",
        pkg: String? = nil,
        app: String? = nil,
        title: String? = nil,
        text: String? = nil,
        icon: String? = nil,
        timestamp: Int64? = Int64(Date().timeIntervalSince1970 * 1000),
        actions: [BridgeNotificationAction]? = nil
    ) {
        self.id = id
        self.source = source
        self.pkg = pkg
        self.app = app
        self.title = title
        self.text = text
        self.icon = icon
        self.timestamp = timestamp
        self.actions = actions
    }

    public var iconImage: NSImage? {
        guard let base64 = icon,
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return NSImage(data: data)
    }

    public var relativeTimeText: String {
        guard let ts = timestamp else { return "now" }
        let seconds = max(0, Int((Date().timeIntervalSince1970 * 1000 - Double(ts)) / 1000))
        if seconds < 60 { return "just now" }
        let mins = seconds / 60
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

public struct NotificationActionRequest: Codable {
    public var type: String = "notif_action"
    public let id: String
    public let actionId: Int
    public let replyText: String?

    public init(id: String, actionId: Int, replyText: String? = nil) {
        self.type = "notif_action"
        self.id = id
        self.actionId = actionId
        self.replyText = replyText
    }
}

public struct NotificationDismissRequest: Codable {
    public var type: String = "notif_dismiss"
    public let id: String
    public let target: String

    public init(id: String, target: String = "android") {
        self.type = "notif_dismiss"
        self.id = id
        self.target = target
    }
}
