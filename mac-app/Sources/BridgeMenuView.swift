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

            // Title (Sender name)
            if let title = notification.title, !title.isEmpty {
                Text(title)
                    .font(.custom("PlusJakartaSans-SemiBold", size: 13.5))
                    .foregroundColor(BridgeColors.text)
                    .lineLimit(2)
            }

            // Body Text (Notification content)
            if let text = notification.text, !text.isEmpty {
                Text(text)
                    .font(.custom("PlusJakartaSans-Regular", size: 12))
                    .foregroundColor(BridgeColors.soft)
                    .lineSpacing(2.5)
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

            // Reply failure error state
            if let errorMsg = manager.replyErrors[notification.id] {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(BridgeColors.coral)

                    Text(errorMsg)
                        .font(.custom("PlusJakartaSans-Regular", size: 11))
                        .foregroundColor(BridgeColors.coral)

                    Spacer()

                    if let replyAction = notification.actions?.first(where: { $0.hasInput }) {
                        Button(action: {
                            submitReply(actionId: replyAction.id)
                        }) {
                            Text("Retry")
                                .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                .foregroundColor(BridgeColors.coral)
                                .underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 1)
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

    private var isPairedOrConnected: Bool {
        model.isConnected || model.pairedDevice != nil
    }

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

                    Text(model.statusText)
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
                        Text("Bridge update available")
                            .font(.custom("PlusJakartaSans-SemiBold", size: 13.5))
                            .foregroundColor(BridgeColors.text)
                            .lineLimit(1)

                        HStack(spacing: 4) {
                            Text("Version \(updateVer) ·")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)

                            Button(action: {
                                model.openReleaseNotes()
                            }) {
                                Text("View release notes")
                                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                    .foregroundColor(BridgeColors.lime)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        }
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

            // Device Card (Visible while paired or connected)
            if isPairedOrConnected {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(model.isConnected ? BridgeColors.lime : BridgeColors.line)
                            .frame(width: 40, height: 40)

                        Image(systemName: "iphone")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(model.isConnected ? BridgeColors.ink : BridgeColors.soft)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.connectedDevice ?? model.pairedDevice ?? "Phone")
                            .font(.custom("PlusJakartaSans-Medium", size: 14))
                            .foregroundColor(BridgeColors.text)
                            .kerning(-0.15)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(model.isConnected ? "Connected · Same Wi-Fi" : "Disconnected · Check Wi-Fi")
                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 6)

                    Button(action: {
                        model.showUnpairConfirmation.toggle()
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
                    .help("Unpair this phone")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(BridgeColors.panel)
                )

                if model.showUnpairConfirmation {
                    // Unpair Confirmation Dialog
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(BridgeColors.coral)

                            Text("Unpair this phone?")
                                .font(.custom("PlusJakartaSans-SemiBold", size: 13))
                                .foregroundColor(BridgeColors.text)
                        }

                        Text("This will remove the pairing between your phone and Mac. You'll need to pair them again to reconnect.")
                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineSpacing(2)

                        HStack(spacing: 8) {
                            Spacer()

                            Button(action: {
                                model.showUnpairConfirmation = false
                            }) {
                                Text("Cancel")
                                    .font(.custom("PlusJakartaSans-Medium", size: 12))
                                    .foregroundColor(BridgeColors.soft)
                                    .padding(.horizontal, 12)
                                    .frame(height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(BridgeColors.line2, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                model.showUnpairConfirmation = false
                                model.unpair()
                            }) {
                                Text("Unpair")
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 12))
                                    .foregroundColor(BridgeColors.ink)
                                    .padding(.horizontal, 14)
                                    .frame(height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(BridgeColors.coral)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(BridgeColors.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(BridgeColors.coral.opacity(0.4), lineWidth: 1)
                    )
                } else {
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
                    if !model.showPairingSection {
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
                                        Text("Allow Bridge in System Settings → Notifications to display mirrored notifications.")
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
                                        .foregroundColor(BridgeColors.coral)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Mac Alert Forwarding Paused")
                                            .font(.custom("PlusJakartaSans-Medium", size: 13))
                                            .foregroundColor(BridgeColors.text)
                                        Text("Grant Accessibility permission to forward Mac notifications to your phone.")
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

                        if notifManager.activeNotifications.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: notifManager.isEffectiveAndroidReceiveEnabled ? "bell.slash" : "pause.circle.fill")
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
                                        Text("Clear notifications")
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

                    // Toggle Button to add another phone (Only visible on Notifications tab)
                    Button(action: {
                        model.showPairingSection.toggle()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: model.showPairingSection ? "chevron.up" : "plus.circle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(BridgeColors.lime)

                            Text(model.showPairingSection ? "Hide pairing code" : "Add another phone")
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

                // Tab 2: Settings
                if model.selectedTab == .settings {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SYNCED SETTINGS")
                            .font(.custom("DMMono-Regular", size: 10.5))
                            .foregroundColor(BridgeColors.muted)
                            .kerning(1.0)

                        // Main Master Notification Option
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Notifications")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text("Sync notifications between your Mac and Android phone.")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                Spacer()
                                Toggle("", isOn: $notifManager.isMasterNotificationsEnabled)
                                    .labelsHidden()
                                    .toggleStyle(BridgeSwitchToggleStyle())
                            }

                            if !notifManager.isMasterNotificationsEnabled {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(BridgeColors.coral)
                                        .frame(width: 6, height: 6)
                                    Text("Paused while notification sync is off.")
                                        .font(.custom("PlusJakartaSans-Medium", size: 11.5))
                                        .foregroundColor(BridgeColors.coral)
                                }
                                .padding(.top, 2)
                            }
                        }

                        // Sub-options for Android and Mac notifications
                        HStack(alignment: .top, spacing: 10) {
                            Rectangle()
                                .fill(notifManager.isMasterNotificationsEnabled ? BridgeColors.lime.opacity(0.45) : BridgeColors.line)
                                .frame(width: 2)
                                .cornerRadius(1)
                                .padding(.vertical, 2)
                                .padding(.leading, 4)

                            VStack(alignment: .leading, spacing: 8) {
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
                                Text("Play a sound when a phone notification arrives.")
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

                        Divider().background(BridgeColors.line)

                        // System Permissions Section
                        Text("SYSTEM PERMISSIONS")
                            .font(.custom("DMMono-Regular", size: 10.5))
                            .foregroundColor(BridgeColors.muted)
                            .kerning(1.0)

                        // Permission 1: Mac Banners
                        Button(action: {
                            if !notifManager.isSystemNotificationAllowed {
                                notifManager.openNotificationSettings()
                            }
                        }) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(notifManager.isSystemNotificationAllowed ? BridgeColors.lime : BridgeColors.coral)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Banner Notifications")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text(
                                        notifManager.isSystemNotificationAllowed
                                            ? "Authorized to display mirrored notifications."
                                            : "Allow Bridge in System Settings → Notifications."
                                    )
                                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                    .foregroundColor(BridgeColors.muted)
                                }

                                Spacer()

                                if notifManager.isSystemNotificationAllowed {
                                    Text("Active")
                                        .font(.custom("PlusJakartaSans-SemiBold", size: 10))
                                        .foregroundColor(BridgeColors.lime)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(BridgeColors.lime.opacity(0.16))
                                        )
                                } else {
                                    HStack(spacing: 4) {
                                        Text("Required")
                                            .font(.custom("PlusJakartaSans-SemiBold", size: 10))
                                            .foregroundColor(BridgeColors.coral)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(BridgeColors.coral.opacity(0.16))
                                            )
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(BridgeColors.muted)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider().background(BridgeColors.line.opacity(0.6))

                        // Permission 2: Mac Accessibility
                        Button(action: {
                            if !axObserver.isAccessibilityTrusted {
                                axObserver.promptAccessibilityPermissions()
                            }
                        }) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(axObserver.isAccessibilityTrusted ? BridgeColors.lime : BridgeColors.coral)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Accessibility Permission")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text(
                                        axObserver.isAccessibilityTrusted
                                            ? "Authorized to capture Mac alerts for sync."
                                            : "Grant Accessibility permission in System Settings."
                                    )
                                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                    .foregroundColor(BridgeColors.muted)
                                }

                                Spacer()

                                if axObserver.isAccessibilityTrusted {
                                    Text("Active")
                                        .font(.custom("PlusJakartaSans-SemiBold", size: 10))
                                        .foregroundColor(BridgeColors.lime)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule().fill(BridgeColors.lime.opacity(0.16))
                                        )
                                } else {
                                    HStack(spacing: 4) {
                                        Text("Required")
                                            .font(.custom("PlusJakartaSans-SemiBold", size: 10))
                                            .foregroundColor(BridgeColors.coral)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(BridgeColors.coral.opacity(0.16))
                                            )
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(BridgeColors.muted)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(13)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(BridgeColors.panel)
                    )
                }
                }
            }

            // Pairing Card (Visible when NOT paired/connected, OR when user clicks "Add another phone" on Notifications tab)
            if !isPairedOrConnected || (!model.showUnpairConfirmation && model.selectedTab == .notifications && model.showPairingSection) {
                let qrSize: CGFloat = isPairedOrConnected ? 152 : 176
                VStack(spacing: isPairedOrConnected ? 10 : 12) {
                    Text(isPairedOrConnected ? "ADD ANOTHER PHONE" : "PAIR YOUR PHONE")
                        .font(.custom("DMMono-Regular", size: 11))
                        .foregroundColor(BridgeColors.muted)
                        .kerning(1.54)
                        .padding(.top, 2)

                    // Off-white QR tile
                    ZStack {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(BridgeColors.text)
                            .frame(width: qrSize, height: qrSize)

                        if let qrImg = model.qrCodeImage {
                            Image(nsImage: qrImg)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(isPairedOrConnected ? 10 : 12)
                                .frame(width: qrSize, height: qrSize)
                        }
                    }

                    VStack(spacing: 3) {
                        Text("Open Bridge on your Android phone and scan this QR code to connect.")
                            .font(.custom("PlusJakartaSans-Regular", size: 12.5))
                            .foregroundColor(BridgeColors.soft)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)

                        if isPairedOrConnected {
                            Text("Your existing phone will remain connected while pairing another phone.")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 10)
                                .padding(.top, 1)
                        }
                    }

                    // Rule
                    Rectangle()
                        .fill(BridgeColors.line)
                        .frame(height: 1)
                        .padding(.horizontal, 4)

                    // 6-digit code area with PAIRING CODE label
                    VStack(spacing: 4) {
                        Text("PAIRING CODE")
                            .font(.custom("DMMono-Regular", size: 10))
                            .foregroundColor(BridgeColors.muted)
                            .kerning(1.2)

                        HStack(spacing: 12) {
                            Text(model.formattedCode)
                                .font(.custom("DMMono-Medium", size: isPairedOrConnected ? 27 : 30))
                                .foregroundColor(BridgeColors.lime)
                                .kerning(1.8)

                            Button(action: {
                                model.copyPairingCode()
                            }) {
                                Text(model.copiedNotice ? "Copied" : "Copy")
                                    .font(.custom("PlusJakartaSans-Medium", size: 13.5))
                                    .foregroundColor(model.copiedNotice ? BridgeColors.ink : BridgeColors.text)
                                    .frame(minWidth: 80, minHeight: isPairedOrConnected ? 38 : 44)
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
                    }
                    .padding(.bottom, 2)
                }
                .padding(isPairedOrConnected ? 15 : 18)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(BridgeColors.panel)
                )
            }

            // Footer Bar
            HStack {
                HStack(spacing: 4) {
                    Text("\(model.localIp):\(String(model.port))")
                        .font(.custom("DMMono-Regular", size: 11.5))
                        .foregroundColor(BridgeColors.muted)
                }

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
