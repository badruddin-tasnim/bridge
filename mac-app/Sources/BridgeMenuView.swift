import SwiftUI
import AppKit

// MARK: - Design Tokens & Styles

struct BridgeColors {
    static let ink = Color(red: 0x0E / 255.0, green: 0x0F / 255.0, blue: 0x12 / 255.0)
    static let bg = Color(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0)
    static let panel = Color(red: 0x1C / 255.0, green: 0x1F / 255.0, blue: 0x25 / 255.0)
    static let line = Color(red: 0x2B / 255.0, green: 0x2F / 255.0, blue: 0x36 / 255.0)
    static let line2 = Color(red: 0x3A / 255.0, green: 0x3F / 255.0, blue: 0x47 / 255.0)
    static let text = Color(red: 0xF4 / 255.0, green: 0xF5 / 255.0, blue: 0xF2 / 255.0)
    static let soft = Color(red: 0xC9 / 255.0, green: 0xCE / 255.0, blue: 0xD4 / 255.0)
    static let muted = Color(red: 0x9B / 255.0, green: 0xA3 / 255.0, blue: 0xAD / 255.0)
    static let lime = Color(red: 0xC8 / 255.0, green: 0xF1 / 255.0, blue: 0x35 / 255.0)
    static let coral = Color(red: 0xFF / 255.0, green: 0x9A / 255.0, blue: 0x8A / 255.0)
}

struct BridgeLogoMark: View {
    var body: some View {
        if let img = loadCrispLogo() {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(BridgeColors.lime)
                .frame(width: 32, height: 32)
        }
    }
    
    private func loadCrispLogo() -> NSImage? {
        if let path2x = Bundle.main.path(forResource: "BridgeLogoMark@2x", ofType: "png"),
           let img2x = NSImage(contentsOfFile: path2x) {
            img2x.size = NSSize(width: 32, height: 32)
            return img2x
        }
        if let path = Bundle.main.path(forResource: "BridgeLogoMark", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: 32, height: 32)
            return img
        }
        return nil
    }
}

/// Crisp vector unlink / unpair icon in a 24x24 coordinate space
struct UnlinkIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sx = rect.width / 24.0
        let sy = rect.height / 24.0
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }
        
        // Top-right link half
        path.move(to: pt(18.84, 12.25))
        path.addLine(to: pt(20.56, 10.54))
        path.addCurve(to: pt(20.44, 3.47), control1: pt(22.45, 8.65), control2: pt(22.40, 5.43))
        path.addCurve(to: pt(13.49, 3.47), control1: pt(18.52, 1.55), control2: pt(15.41, 1.55))
        path.addLine(to: pt(11.77, 5.18))
        
        // Bottom-left link half
        path.move(to: pt(5.17, 11.75))
        path.addLine(to: pt(3.46, 13.46))
        path.addCurve(to: pt(3.58, 20.53), control1: pt(1.57, 15.35), control2: pt(1.62, 18.57))
        path.addCurve(to: pt(10.53, 20.53), control1: pt(5.50, 22.45), control2: pt(8.61, 22.45))
        path.addLine(to: pt(12.24, 18.82))
        
        // Break ticks (top-left & bottom-right)
        path.move(to: pt(8, 2))
        path.addLine(to: pt(8, 5))
        path.move(to: pt(2, 8))
        path.addLine(to: pt(5, 8))
        path.move(to: pt(16, 19))
        path.addLine(to: pt(16, 22))
        path.move(to: pt(19, 16))
        path.addLine(to: pt(22, 16))
        
        return path
    }
}

// MARK: - Notification Card Item

struct NotificationCardView: View {
    let notification: BridgeNotification
    @ObservedObject var manager: BridgeNotificationManager

    private var replyBinding: Binding<String> {
        Binding(
            get: { manager.replyDrafts[notification.id] ?? "" },
            set: { manager.replyDrafts[notification.id] = $0 }
        )
    }

    private var isReplyEmpty: Bool {
        (manager.replyDrafts[notification.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: App icon + App name + Time + Close
            HStack(spacing: 8) {
                if let icon = notification.iconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .cornerRadius(4)
                } else {
                    Image(systemName: "app.badge.fill")
                        .font(.system(size: 14))
                        .foregroundColor(BridgeColors.lime)
                }

                Text(notification.app ?? "Phone")
                    .font(.custom("PlusJakartaSans-SemiBold", size: 12.5))
                    .foregroundColor(BridgeColors.text)
                    .lineLimit(1)

                Text("•")
                    .font(.system(size: 10))
                    .foregroundColor(BridgeColors.muted)

                Text(notification.relativeTimeText)
                    .font(.custom("PlusJakartaSans-Regular", size: 11))
                    .foregroundColor(BridgeColors.muted)

                Spacer()

                Button(action: {
                    manager.dismiss(id: notification.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(BridgeColors.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss notification")
            }

            // Title
            if let title = notification.title, !title.isEmpty {
                Text(title)
                    .font(.custom("PlusJakartaSans-Medium", size: 13))
                    .foregroundColor(BridgeColors.text)
                    .lineLimit(2)
            }

            // Body Text
            if let text = notification.text, !text.isEmpty {
                Text(text)
                    .font(.custom("PlusJakartaSans-Regular", size: 12))
                    .foregroundColor(BridgeColors.soft)
                    .lineLimit(4)
            }

            // Inline Reply Field (if reply action exists)
            if let replyAction = notification.actions?.first(where: { $0.hasInput }) {
                HStack(spacing: 8) {
                    TextField(replyAction.placeholder ?? "Reply…", text: replyBinding, onCommit: {
                        submitReply(actionId: replyAction.id)
                    })
                    .textFieldStyle(.plain)
                    .font(.custom("PlusJakartaSans-Regular", size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(BridgeColors.bg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(BridgeColors.line2, lineWidth: 1)
                    )

                    Button(action: {
                        submitReply(actionId: replyAction.id)
                    }) {
                        Text("Send")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 11.5))
                            .foregroundColor(BridgeColors.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(BridgeColors.lime)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isReplyEmpty)
                }
                .padding(.top, 2)
            }

            // Standard Action Buttons (e.g. "Mark as read", "Archive")
            if let actions = notification.actions?.filter({ !$0.hasInput }), !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        Button(action: {
                            manager.sendAction(id: notification.id, actionId: action.id)
                        }) {
                            Text(action.title)
                                .font(.custom("PlusJakartaSans-Medium", size: 11))
                                .foregroundColor(BridgeColors.soft)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(BridgeColors.line2, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(BridgeColors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(BridgeColors.line2.opacity(0.4), lineWidth: 1)
        )
    }

    private func submitReply(actionId: Int) {
        let text = manager.replyDrafts[notification.id] ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manager.sendReply(id: notification.id, actionId: actionId, replyText: trimmed)
        manager.replyDrafts[notification.id] = ""
    }
}

// MARK: - Isolated Status Dot View

final class StatusDotTicker: ObservableObject {
    static let shared = StatusDotTicker()
    @Published var breathe: Bool = false
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.breathe.toggle()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        breathe = false
    }
}

struct StatusDotView: View {
    let isConnected: Bool
    @ObservedObject private var ticker = StatusDotTicker.shared

    var body: some View {
        Circle()
            .fill(isConnected ? BridgeColors.lime : BridgeColors.muted)
            .frame(width: 7, height: 7)
            .scaleEffect(ticker.breathe && isConnected ? 0.8 : 1.0)
            .opacity(ticker.breathe && isConnected ? 0.35 : 1.0)
            .animation(
                isConnected ? Animation.easeInOut(duration: 1.2) : .default,
                value: ticker.breathe
            )
    }
}

struct BridgeSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.16)) {
                configuration.isOn.toggle()
            }
        }) {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? BridgeColors.lime : BridgeColors.line2)
                    .frame(width: 38, height: 22)

                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Main Menu Bar View

struct BridgeMenuView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var notifManager: BridgeNotificationManager = BridgeNotificationManager.shared
    @ObservedObject var axObserver: AXNotificationObserver = AXNotificationObserver.shared

    var body: some View {
        VStack(spacing: 12) {
            // Header Bar
            HStack(spacing: 10) {
                BridgeLogoMark()

                Text("bridge")
                    .font(.custom("PlusJakartaSans-Medium", size: 21))
                    .foregroundColor(BridgeColors.text)
                    .kerning(-0.4)

                Spacer()

                // Status indicator
                HStack(spacing: 6) {
                    StatusDotView(isConnected: model.isConnected)

                    Text(model.isConnected ? "ONLINE" : "WAITING")
                        .font(.custom("DMMono-Regular", size: 11))
                        .foregroundColor(model.isConnected ? BridgeColors.lime : BridgeColors.muted)
                        .kerning(0.88)
                }
            }
            .padding(.top, 4)
            .fixedSize(horizontal: false, vertical: true)

            // Update Notification Banner
            if let updateVer = model.availableUpdateVersion {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bridge v\(updateVer) is available")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 13.5))
                            .foregroundColor(BridgeColors.text)
                            .lineLimit(1)

                        Text("New release ready on GitHub")
                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Button(action: {
                        model.openUpdateDownload()
                    }) {
                        Text("Update")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 12))
                            .foregroundColor(BridgeColors.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(BridgeColors.lime)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        model.dismissUpdateForToday()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(BridgeColors.muted)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss for today")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(BridgeColors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(BridgeColors.lime.opacity(0.35), lineWidth: 1)
                )
            }

            // Device Card (Visible while connected)
            if model.isConnected {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(BridgeColors.lime)
                            .frame(width: 40, height: 40)

                        Image(systemName: "iphone")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(BridgeColors.ink)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.connectedDevice ?? "Galaxy A52s")
                            .font(.custom("PlusJakartaSans-Medium", size: 14))
                            .foregroundColor(BridgeColors.text)
                            .kerning(-0.15)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Linked to this Mac, same Wi-Fi")
                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 6)

                    Button(action: {
                        model.unpair()
                    }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(BridgeColors.coral.opacity(0.08))
                                .frame(width: 34, height: 34)

                            RoundedRectangle(cornerRadius: 10)
                                .stroke(BridgeColors.coral.opacity(0.38), lineWidth: 1)
                                .frame(width: 34, height: 34)

                            UnlinkIconShape()
                                .stroke(
                                    BridgeColors.coral,
                                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                                )
                                .frame(width: 15, height: 15)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Unpair device")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(BridgeColors.panel)
                )

                // Tab Switcher: [Notifications (count)]  [Settings]
                HStack(spacing: 6) {
                    Button(action: {
                        if model.selectedTab != .notifications {
                            model.selectedTab = .notifications
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 12))
                            Text("Notifications")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))

                            if !notifManager.activeNotifications.isEmpty {
                                Text("\(notifManager.activeNotifications.count)")
                                    .font(.custom("DMMono-Medium", size: 10.5))
                                    .foregroundColor(BridgeColors.ink)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule()
                                            .fill(BridgeColors.lime)
                                    )
                            }
                        }
                        .foregroundColor(model.selectedTab == .notifications ? BridgeColors.lime : BridgeColors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.selectedTab == .notifications ? BridgeColors.panel : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        if model.selectedTab != .settings {
                            model.selectedTab = .settings
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 12))
                            Text("Settings")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))
                        }
                        .foregroundColor(model.selectedTab == .settings ? BridgeColors.lime : BridgeColors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.selectedTab == .settings ? BridgeColors.panel : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(4)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(BridgeColors.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(BridgeColors.line, lineWidth: 1)
                )

                // Tab 1: Notifications
                if model.selectedTab == .notifications {
                    if !notifManager.isSystemNotificationAllowed && notifManager.isEffectiveAndroidReceiveEnabled {
                        Button(action: {
                            notifManager.openNotificationSettings()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(BridgeColors.coral)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Banners Disabled")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text("Click to allow Bridge in System Settings > Notifications")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(BridgeColors.muted)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(BridgeColors.coral.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(BridgeColors.coral.opacity(0.35), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !axObserver.isAccessibilityTrusted && notifManager.isEffectiveMacForwardEnabled {
                        Button(action: {
                            axObserver.promptAccessibilityPermissions()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(BridgeColors.lime)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Alert Forwarding Paused")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text("Click to grant Accessibility permission in System Settings")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(BridgeColors.muted)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(BridgeColors.lime.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(BridgeColors.lime.opacity(0.35), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if notifManager.activeNotifications.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 24))
                                .foregroundColor(BridgeColors.muted.opacity(0.6))
                                .padding(.top, 4)

                            Text(notifManager.isEffectiveAndroidReceiveEnabled ? "No new notifications" : "Notifications paused")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))
                                .foregroundColor(BridgeColors.soft)

                            Text(
                                notifManager.isEffectiveAndroidReceiveEnabled
                                    ? "Notifications from your phone will appear here in real time."
                                    : "Android notifications are turned off in Settings."
                            )
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                        }
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(BridgeColors.panel.opacity(0.6))
                        )
                    } else {
                        VStack(spacing: 8) {
                            HStack {
                                Text("MIRRORED NOTIFICATIONS")
                                    .font(.custom("DMMono-Regular", size: 10.5))
                                    .foregroundColor(BridgeColors.muted)
                                    .kerning(1.0)

                                Spacer()

                                Button(action: {
                                    notifManager.clearAll()
                                }) {
                                    Text("Clear All")
                                        .font(.custom("PlusJakartaSans-Medium", size: 11.5))
                                        .foregroundColor(BridgeColors.coral)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 4)

                            if notifManager.activeNotifications.count <= 2 {
                                VStack(spacing: 8) {
                                    ForEach(notifManager.activeNotifications) { notif in
                                        NotificationCardView(notification: notif, manager: notifManager)
                                    }
                                }
                            } else {
                                ScrollView(.vertical, showsIndicators: true) {
                                    VStack(spacing: 8) {
                                        ForEach(notifManager.activeNotifications) { notif in
                                            NotificationCardView(notification: notif, manager: notifManager)
                                        }
                                    }
                                    .padding(.trailing, 2)
                                }
                                .frame(height: 280)
                            }
                        }
                    }
                }

                // Tab 2: Settings
                if model.selectedTab == .settings {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SYNCED SETTINGS")
                            .font(.custom("DMMono-Regular", size: 10.5))
                            .foregroundColor(BridgeColors.muted)
                            .kerning(1.0)

                        // Main Master Notification Option
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notifications")
                                    .font(.custom("PlusJakartaSans-Medium", size: 13))
                                    .foregroundColor(BridgeColors.text)
                                Text("Sync notifications between Mac and phone")
                                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                    .foregroundColor(BridgeColors.muted)
                            }
                            Spacer()
                            Toggle("", isOn: $notifManager.isMasterNotificationsEnabled)
                                .labelsHidden()
                                .toggleStyle(BridgeSwitchToggleStyle())
                        }

                        // Sub-options for Android and Mac notifications
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle()
                                .fill(notifManager.isMasterNotificationsEnabled ? BridgeColors.lime.opacity(0.45) : BridgeColors.line)
                                .frame(width: 2)
                                .cornerRadius(1)
                                .padding(.vertical, 2)
                                .padding(.leading, 4)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Android Notifications")
                                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                                            .foregroundColor(BridgeColors.text)
                                        Text("Show phone notifications on this Mac")
                                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                            .foregroundColor(BridgeColors.muted)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $notifManager.isMirroringEnabled)
                                        .labelsHidden()
                                        .toggleStyle(BridgeSwitchToggleStyle())
                                        .disabled(!notifManager.isMasterNotificationsEnabled)
                                }

                                Divider().background(BridgeColors.line.opacity(0.6))

                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Mac Notifications")
                                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                                            .foregroundColor(BridgeColors.text)
                                        Text("Show Mac notifications on your phone")
                                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                            .foregroundColor(BridgeColors.muted)
                                    }
                                    Spacer()
                                    Toggle("", isOn: $notifManager.isMacAlertsForwardingEnabled)
                                        .labelsHidden()
                                        .toggleStyle(BridgeSwitchToggleStyle())
                                        .disabled(!notifManager.isMasterNotificationsEnabled)
                                }
                            }
                        }
                        .opacity(notifManager.isMasterNotificationsEnabled ? 1.0 : 0.45)

                        Divider().background(BridgeColors.line)

                        // Mac-Only Settings Section
                        Text("MAC ONLY")
                            .font(.custom("DMMono-Regular", size: 10.5))
                            .foregroundColor(BridgeColors.muted)
                            .kerning(1.0)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Play Notification Sounds")
                                    .font(.custom("PlusJakartaSans-Medium", size: 13))
                                    .foregroundColor(BridgeColors.text)
                                Text("Chime on Mac when a phone alert arrives")
                                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                    .foregroundColor(BridgeColors.muted)
                            }
                            Spacer()
                            Toggle("", isOn: $notifManager.isSoundEnabled)
                                .labelsHidden()
                                .toggleStyle(BridgeSwitchToggleStyle())
                                .disabled(!notifManager.isEffectiveAndroidReceiveEnabled)
                        }
                        .opacity(notifManager.isEffectiveAndroidReceiveEnabled ? 1.0 : 0.45)

                        if !notifManager.isSystemNotificationAllowed {
                            Divider().background(BridgeColors.line)

                            Button(action: {
                                notifManager.openNotificationSettings()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "bell.badge.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(BridgeColors.coral)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Allow Mac Banners")
                                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                                            .foregroundColor(BridgeColors.text)
                                        Text("Enable in System Settings > Notifications")
                                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                            .foregroundColor(BridgeColors.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                .padding(.top, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !axObserver.isAccessibilityTrusted {
                            Divider().background(BridgeColors.line)

                            Button(action: {
                                axObserver.promptAccessibilityPermissions()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "hand.raised.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(BridgeColors.lime)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Mac Accessibility Permission")
                                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                                            .foregroundColor(BridgeColors.text)
                                        Text("Required to capture Mac alerts. Click to open System Settings.")
                                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                            .foregroundColor(BridgeColors.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(BridgeColors.lime.opacity(0.12))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(BridgeColors.lime.opacity(0.35), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(BridgeColors.panel)
                    )
                }

                // Toggle Button to pair another phone
                Button(action: {
                    model.showPairingSection.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: model.showPairingSection ? "chevron.up" : "plus.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(BridgeColors.lime)

                        Text(model.showPairingSection ? "Hide pairing code" : "Pair another phone")
                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                            .foregroundColor(BridgeColors.soft)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(BridgeColors.line2, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Pairing Card (Visible when NOT connected, OR when user clicks "Pair another phone")
            if !model.isConnected || model.showPairingSection {
                VStack(spacing: 12) {
                    Text(model.isConnected ? "PAIR ANOTHER PHONE" : "PAIR YOUR PHONE")
                        .font(.custom("DMMono-Regular", size: 11))
                        .foregroundColor(BridgeColors.muted)
                        .kerning(1.54)
                        .padding(.top, 4)

                    // 176pt off-white QR tile
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(BridgeColors.text)
                            .frame(width: 176, height: 176)

                        if let qrImg = model.qrCodeImage {
                            Image(nsImage: qrImg)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                                .frame(width: 176, height: 176)
                        }
                    }

                    Text("Open Bridge on Android and point it here")
                        .font(.custom("PlusJakartaSans-Regular", size: 13.5))
                        .foregroundColor(BridgeColors.soft)
                        .multilineTextAlignment(.center)

                    // Rule
                    Rectangle()
                        .fill(BridgeColors.line)
                        .frame(height: 1)
                        .padding(.horizontal, 4)

                    // 6-digit code row with Copy button
                    HStack(spacing: 12) {
                        Text(model.formattedCode)
                            .font(.custom("DMMono-Medium", size: 30))
                            .foregroundColor(BridgeColors.lime)
                            .kerning(1.8)

                        Button(action: {
                            model.copyPairingCode()
                        }) {
                            Text(model.copiedNotice ? "Copied" : "Copy")
                                .font(.custom("PlusJakartaSans-Medium", size: 14))
                                .foregroundColor(model.copiedNotice ? BridgeColors.ink : BridgeColors.text)
                                .frame(minWidth: 84, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(model.copiedNotice ? BridgeColors.lime : Color.clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(model.copiedNotice ? BridgeColors.lime : BridgeColors.line2, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, 4)
                }
                .padding(18)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(BridgeColors.panel)
                )
            }

            // Footer Bar
            HStack {
                Text("\(model.localIp):\(String(model.port))")
                    .font(.custom("DMMono-Regular", size: 12))
                    .foregroundColor(BridgeColors.muted)

                Spacer()

                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Text("Quit Bridge")
                        .font(.custom("PlusJakartaSans-Regular", size: 12))
                        .foregroundColor(BridgeColors.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 380)
        .background(
            BridgeColors.bg
                .padding(.top, -80)
                .padding(.bottom, -40)
                .ignoresSafeArea()
        )
        .onAppear {
            axObserver.checkTrustNow()
        }
    }
}
