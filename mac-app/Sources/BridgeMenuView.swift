import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Design Tokens & Styles

struct BridgeColors {
    static let ink = Color(red: 0x0E / 255.0, green: 0x0F / 255.0, blue: 0x12 / 255.0)
    static let bg = Color(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0)
    static let panel = Color(red: 0x1C / 255.0, green: 0x1F / 255.0, blue: 0x25 / 255.0)
    static let line = Color(red: 0x2B / 255.0, green: 0x2F / 255.0, blue: 0x36 / 255.0)
    static let line2 = Color(red: 0x3A / 255.0, green: 0x3F / 255.0, blue: 0x47 / 255.0)
    static let activeTab = Color(red: 0x25 / 255.0, green: 0x2C / 255.0, blue: 0x1A / 255.0)
    static let text = Color(red: 0xF4 / 255.0, green: 0xF5 / 255.0, blue: 0xF2 / 255.0)
    static let soft = Color(red: 0xC9 / 255.0, green: 0xCE / 255.0, blue: 0xD4 / 255.0)
    static let muted = Color(red: 0x9B / 255.0, green: 0xA3 / 255.0, blue: 0xAD / 255.0)
    static let lime = Color(red: 0xC8 / 255.0, green: 0xF1 / 255.0, blue: 0x35 / 255.0)
    static let amber = Color(red: 0xF5 / 255.0, green: 0xA6 / 255.0, blue: 0x23 / 255.0)
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

struct BatteryRingView: View {
    let level: Int?
    let isCharging: Bool
    let isStale: Bool

    private let ringSize: CGFloat = 38
    private let ringStroke: CGFloat = 3.8
    private let badgeSize: CGFloat = 15

    private var hasValidLevel: Bool {
        level != nil && !isStale
    }

    private var clampedLevel: Int {
        max(0, min(100, level ?? 0))
    }

    private var ringColor: Color {
        guard hasValidLevel else {
            return BridgeColors.line2.opacity(0.75)
        }
        if isCharging {
            return BridgeColors.amber
        }
        return clampedLevel <= 15 ? BridgeColors.coral : BridgeColors.lime
    }

    var body: some View {
        ZStack(alignment: .center) {
            ZStack {
                Circle()
                    .stroke(BridgeColors.line2.opacity(0.75), lineWidth: ringStroke)

                if hasValidLevel {
                    Circle()
                        .trim(from: 0, to: CGFloat(clampedLevel) / 100.0)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: ringStroke, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.25), value: clampedLevel)
                        .animation(.easeInOut(duration: 0.25), value: isCharging)
                }

                if !hasValidLevel {
                    Text("--")
                        .font(.custom("DMMono-Medium", size: 11.5))
                        .foregroundColor(BridgeColors.muted)
                } else {
                    Text("\(clampedLevel)")
                        .font(.custom("PlusJakartaSans-SemiBold", size: clampedLevel == 100 ? 11 : 12.5))
                        .foregroundColor(BridgeColors.text)
                        .offset(y: isCharging ? 2.5 : 0)
                }
            }
            .frame(width: ringSize, height: ringSize)
            .offset(y: 3)

            if hasValidLevel && isCharging {
                ZStack {
                    Circle()
                        .fill(BridgeColors.amber)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: badgeSize, height: badgeSize)
                .offset(y: -(ringSize / 2) + 3)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 44, height: 48)
        .animation(.easeInOut(duration: 0.2), value: isCharging)
    }
}

struct QuickControlTileButton: View {
    let iconName: String
    let label: String
    let fillColor: Color
    let borderColor: Color
    let iconColor: Color
    let labelColor: Color
    let helpText: String
    var isPending: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(fillColor)
                        .frame(height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(borderColor, lineWidth: 1)
                        )

                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                        .opacity(isPending ? 0.55 : 1.0)
                }

                Text(label)
                    .font(.custom("PlusJakartaSans-Medium", size: 10.5))
                    .foregroundColor(labelColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
    }
}

struct NowPlayingCardView: View {
    let device: ConnectedDeviceInfo
    let media: MediaPlaybackInfo
    @ObservedObject var model: BridgeModel

    private static func formatTime(ms: Int64) -> String {
        let totalSeconds = max(0, Int(ms / 1000))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var subtitleText: String {
        if !media.artist.isEmpty && !media.album.isEmpty && media.album != media.artist {
            return "\(media.artist) · \(media.album)"
        }
        if !media.artist.isEmpty {
            return media.artist
        }
        if !media.album.isEmpty {
            return media.album
        }
        return media.appName.isEmpty ? "Playing on phone" : media.appName
    }

    private var volumeIconName: String {
        if media.volumeIndex <= 0 {
            return "speaker.slash.fill"
        }
        let ratio = Double(media.volumeIndex) / Double(max(1, media.maxVolume))
        return ratio < 0.45 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("NOW PLAYING")
                    .font(.custom("DMMono-Regular", size: 9.5))
                    .foregroundColor(BridgeColors.soft.opacity(0.85))
                    .kerning(1.1)

                Spacer()

                if !media.appName.isEmpty {
                    Text(media.appName)
                        .font(.custom("PlusJakartaSans-Medium", size: 10.5))
                        .foregroundColor(BridgeColors.lime)
                        .lineLimit(1)
                }
            }

            // Track Metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(media.title)
                    .font(.custom("PlusJakartaSans-SemiBold", size: 13.5))
                    .foregroundColor(BridgeColors.text)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                    .foregroundColor(BridgeColors.soft)
                    .lineLimit(1)
            }

            // Center-Aligned Transport Controls: Prev · -10s · Play/Pause · +10s · Next (filtered by session capabilities)
            HStack(spacing: 16) {
                if media.canSkipPrevious {
                    Button(action: {
                        model.sendMediaPrevious(for: device)
                    }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(BridgeColors.text.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Previous track")
                }

                if media.canSeek && media.durationMs > 0 {
                    Button(action: {
                        model.sendMediaSkip(for: device, deltaMs: -10_000)
                    }) {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(BridgeColors.text.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back 10 seconds")
                }

                Button(action: {
                    model.sendMediaPlayPause(for: device)
                }) {
                    ZStack {
                        Circle()
                            .fill(BridgeColors.lime)
                            .frame(width: 34, height: 34)
                        Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(BridgeColors.ink)
                            .offset(x: media.isPlaying ? 0 : 1.0)
                    }
                }
                .buttonStyle(.plain)
                .help(media.isPlaying ? "Pause" : "Play")

                if media.canSeek && media.durationMs > 0 {
                    Button(action: {
                        model.sendMediaSkip(for: device, deltaMs: 10_000)
                    }) {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(BridgeColors.text.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Forward 10 seconds")
                }

                if media.canSkipNext {
                    Button(action: {
                        model.sendMediaNext(for: device)
                    }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(BridgeColors.text.opacity(0.9))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Next track")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)

            // Progress Bar + Elapsed / Remaining Time (only when duration & seek are supported)
            if media.canSeek && media.durationMs > 0 {
                if media.isPlaying {
                    TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                        progressBarSection(positionMs: media.estimatedPositionMs())
                    }
                } else {
                    progressBarSection(positionMs: media.estimatedPositionMs())
                }
            }

            // Android Media Volume Slider (only when volume is controllable)
            if media.canControlVolume {
                HStack(spacing: 8) {
                    Button(action: {
                        let target = media.volumeIndex > 0 ? 0 : max(1, media.maxVolume / 2)
                        model.setMediaVolume(for: device, volumeIndex: target, forceSend: true)
                    }) {
                        Image(systemName: volumeIconName)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(media.volumeIndex > 0 ? BridgeColors.soft : BridgeColors.coral)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(media.volumeIndex > 0 ? "Mute Android media" : "Unmute Android media")

                    GeometryReader { geo in
                        let maxVol = max(1, media.maxVolume)
                        let fraction = max(0.0, min(1.0, Double(media.volumeIndex) / Double(maxVol)))
                        let width = max(1, geo.size.width)

                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.22))
                                .frame(height: 4)

                            Capsule()
                                .fill(BridgeColors.lime)
                                .frame(width: max(4, width * CGFloat(fraction)), height: 4)

                            Circle()
                                .fill(BridgeColors.text)
                                .frame(width: 10, height: 10)
                                .offset(x: max(0, min(width - 10, width * CGFloat(fraction) - 5)))
                        }
                        .frame(height: 16)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let pct = max(0.0, min(1.0, Double(value.location.x / width)))
                                    let nextIndex = Int((pct * Double(maxVol)).rounded())
                                    model.setMediaVolume(for: device, volumeIndex: nextIndex, forceSend: false)
                                }
                                .onEnded { value in
                                    let pct = max(0.0, min(1.0, Double(value.location.x / width)))
                                    let nextIndex = Int((pct * Double(maxVol)).rounded())
                                    model.setMediaVolume(for: device, volumeIndex: nextIndex, forceSend: true)
                                }
                        )
                    }
                    .frame(height: 16)
                    .help("Android media volume")

                    let pct = Int(((Double(media.volumeIndex) / Double(max(1, media.maxVolume))) * 100.0).rounded())
                    Text("Phone · \(pct)%")
                        .font(.custom("DMMono-Regular", size: 9.5))
                        .foregroundColor(BridgeColors.soft)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(13)
        .background(
            ZStack {
                if let art = media.artworkImage {
                    GeometryReader { geo in
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }

                    LinearGradient(
                        gradient: Gradient(colors: [
                            BridgeColors.ink.opacity(0.62),
                            BridgeColors.ink.opacity(0.76),
                            BridgeColors.ink.opacity(0.90)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    BridgeColors.bg.opacity(0.85)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(BridgeColors.line2.opacity(0.75), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func progressBarSection(positionMs: Int64) -> some View {
        let duration = max(1, media.durationMs)
        let dragFraction = model.mediaSeekDragFraction[device.id]
        let isHoveredOrDragging = (model.hoveredSeekDeviceId == device.id) || (dragFraction != nil)
        let activeFraction = dragFraction
            ?? max(0.0, min(1.0, Double(positionMs) / Double(duration)))
        let displayPosMs = dragFraction.map { Int64(Double(duration) * $0) }
            ?? positionMs
        let remainingMs = max(0, duration - displayPosMs)

        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = max(1, geo.size.width)
                let trackHeight: CGFloat = isHoveredOrDragging ? 4.5 : 3.5

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(BridgeColors.lime)
                        .frame(width: max(trackHeight, width * CGFloat(activeFraction)), height: trackHeight)

                    let thumbSize: CGFloat = isHoveredOrDragging ? 11 : 6
                    Circle()
                        .fill(Color.white.opacity(isHoveredOrDragging ? 1.0 : 0.85))
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: Color.black.opacity(0.45), radius: 2, x: 0, y: 1)
                        .offset(x: max(0, min(width - thumbSize, width * CGFloat(activeFraction) - thumbSize / 2.0)))
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        model.hoveredSeekDeviceId = device.id
                    } else if model.hoveredSeekDeviceId == device.id {
                        model.hoveredSeekDeviceId = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.mediaSeekDragFraction[device.id] = max(0.0, min(1.0, Double(value.location.x / width)))
                        }
                        .onEnded { value in
                            let pct = max(0.0, min(1.0, Double(value.location.x / width)))
                            model.mediaSeekDragFraction.removeValue(forKey: device.id)
                            model.sendMediaSeek(for: device, positionMs: Int64(Double(duration) * pct))
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(Self.formatTime(ms: displayPosMs))
                    .font(.custom("DMMono-Regular", size: 9.5))
                    .foregroundColor(BridgeColors.soft)
                Spacer()
                Text("-\(Self.formatTime(ms: remainingMs))")
                    .font(.custom("DMMono-Regular", size: 9.5))
                    .foregroundColor(BridgeColors.soft)
            }
        }
    }
}

struct MaskedIpToggleView: View {
    let prefix: String
    let ip: String
    let suffix: String
    let isRevealed: Bool
    let fontName: String
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font(.custom(fontName, size: 11.5))
                    .foregroundColor(BridgeColors.muted)
                    .lineLimit(1)
            }

            Button(action: onToggle) {
                HStack(spacing: 5) {
                    Text("\(isRevealed ? ip : "•••.•••.•••")\(suffix)")
                        .font(.custom(fontName, size: 11.5))
                        .foregroundColor(BridgeColors.muted)
                        .lineLimit(1)

                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(BridgeColors.muted.opacity(0.85))
                        .frame(width: 15, height: 15)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide IP address" : "Show IP address")
        }
        .fixedSize(horizontal: false, vertical: true)
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

                if let count = notification.messages?.count, count > 1 {
                    Text("\(count)")
                        .font(.custom("PlusJakartaSans-SemiBold", size: 10))
                        .foregroundColor(BridgeColors.lime)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(BridgeColors.lime.opacity(0.18))
                        )
                }

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

            // Title (Sender or conversation name)
            if let title = notification.title, !title.isEmpty {
                Text(title)
                    .font(.custom("PlusJakartaSans-SemiBold", size: 13.5))
                    .foregroundColor(BridgeColors.text)
                    .lineLimit(2)
            }

            // Body: Multi-line messages or single content
            if let msgList = notification.messages, msgList.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(msgList) { msg in
                        VStack(alignment: .leading, spacing: 1.5) {
                            if let sender = msg.sender, !sender.isEmpty, sender != notification.title {
                                Text(sender)
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                    .foregroundColor(BridgeColors.lime)
                            }
                            Text(msg.text)
                                .font(.custom("PlusJakartaSans-Regular", size: 12))
                                .foregroundColor(BridgeColors.soft)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if let text = notification.text, !text.isEmpty {
                Text(text)
                    .font(.custom("PlusJakartaSans-Regular", size: 12))
                    .foregroundColor(BridgeColors.soft)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - File Transfer Card View

struct FileTransferCardView: View {
    @ObservedObject var item: FileTransferItem
    let manager: BridgeFileTransferManager

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(BridgeColors.bg)
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(BridgeColors.line2, lineWidth: 1)
                        )

                    Image(systemName: item.iconSymbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(statusAccentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: item.direction == .outgoing ? "arrow.up.right" : "arrow.down.left")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(BridgeColors.muted)

                        Text(item.fileName)
                            .font(.custom("PlusJakartaSans-SemiBold", size: 12.5))
                            .foregroundColor(BridgeColors.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.fileName)
                    }

                    Text(statusSubtitle)
                        .font(.custom("DMMono-Regular", size: 10.5))
                        .foregroundColor(isFailed ? BridgeColors.coral : (item.status == .cancelled ? BridgeColors.muted : (item.status == .completed ? BridgeColors.lime : BridgeColors.muted)))
                        .lineLimit(1)
                        .help(item.status == .completed ? "\(item.direction == .incoming ? "Received from" : "Sent to") \(item.deviceName) (\(item.formattedTotalSize))" : statusSubtitle)

                    if item.status == .transferring && !item.remainingTimeText.isEmpty {
                        Text(item.remainingTimeText)
                            .font(.custom("PlusJakartaSans-Medium", size: 10))
                            .foregroundColor(BridgeColors.soft)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                // Action controls depending on transfer state
                HStack(spacing: 4) {
                    if item.status == .waitingConfirmation && item.direction == .incoming {
                        Button(action: {
                            manager.acceptIncomingTransfer(item)
                        }) {
                            Text("Accept")
                                .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                .foregroundColor(BridgeColors.ink)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.lime)
                                )
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            manager.cancelTransfer(id: item.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.muted)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Decline")
                    } else if item.status == .transferring {
                        Button(action: {
                            manager.pauseTransfer(id: item.id)
                        }) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.soft)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Pause transfer")

                        Button(action: {
                            manager.cancelTransfer(id: item.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.coral)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Cancel transfer")
                    } else if item.status == .paused {
                        Button(action: {
                            manager.resumeTransfer(id: item.id)
                        }) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.lime)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Resume transfer")

                        Button(action: {
                            manager.cancelTransfer(id: item.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.coral)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Cancel transfer")
                    } else if item.status == .hashing || item.status == .waitingConfirmation || item.status == .verifying {
                        Button(action: {
                            manager.cancelTransfer(id: item.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.muted)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Cancel")
                    } else if item.status == .completed, let savedURL = (item.destinationUrl ?? item.sourceUrl) {
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                        }) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(BridgeColors.soft)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")

                        if item.direction == .incoming {
                            Button(action: {
                                NSWorkspace.shared.open(savedURL)
                            }) {
                                Text("Open")
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                    .foregroundColor(BridgeColors.lime)
                                    .padding(.horizontal, 8)
                                    .frame(height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(BridgeColors.lime.opacity(0.35), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    } else if case .failed(let reason) = item.status {
                        if reason.contains("System Settings") || reason.contains("Permission denied") {
                            Button(action: {
                                manager.openFilesAndFoldersSettings()
                            }) {
                                Text("Settings")
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                    .foregroundColor(BridgeColors.lime)
                                    .padding(.horizontal, 8)
                                    .frame(height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(BridgeColors.lime.opacity(0.4), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Open macOS Privacy & Security Settings")
                        } else {
                            Button(action: {
                                manager.retryTransfer(id: item.id)
                            }) {
                                Text("Retry")
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                    .foregroundColor(BridgeColors.lime)
                                    .padding(.horizontal, 8)
                                    .frame(height: 24)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(BridgeColors.lime.opacity(0.4), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Retry transfer")
                        }

                        Button(action: {
                            manager.dismissTransfer(id: item.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.muted)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    } else if item.status == .cancelled {
                        Button(action: {
                            manager.dismissTransfer(id: item.id)
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(BridgeColors.muted)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(BridgeColors.bg)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss")
                    }
                }
            }

            // Progress bar for active/paused transfers
            if item.status == .transferring || item.status == .paused || item.status == .verifying {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(BridgeColors.bg)
                            .frame(height: 5)

                        Capsule()
                            .fill(item.status == .paused ? BridgeColors.muted : BridgeColors.lime)
                            .frame(width: max(6, geo.size.width * CGFloat(item.progress)), height: 5)
                    }
                }
                .frame(height: 5)
            }

            if item.isExecutable {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5))
                        .foregroundColor(BridgeColors.amber)
                    Text("Executable file · Verify sender before opening")
                        .font(.custom("PlusJakartaSans-Medium", size: 10.5))
                        .foregroundColor(BridgeColors.amber)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(BridgeColors.amber.opacity(0.12))
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(BridgeColors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BridgeColors.line2.opacity(0.45), lineWidth: 1)
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private var statusAccentColor: Color {
        switch item.status {
        case .completed:
            return BridgeColors.lime
        case .failed:
            return BridgeColors.coral
        case .cancelled:
            return BridgeColors.muted
        case .paused:
            return BridgeColors.muted
        default:
            return BridgeColors.lime
        }
    }

    private var statusSubtitle: String {
        switch item.status {
        case .hashing:
            return item.isFolder ? "Packaging folder…" : "\(item.formattedTotalSize) · Preparing…"
        case .waitingConfirmation:
            return item.direction == .incoming
                ? "\(item.formattedTotalSize) · From \(item.deviceName)"
                : "\(item.formattedTotalSize) · Connecting to \(item.deviceName)…"
        case .transferring:
            let pct = item.percentageInt
            let speedStr = item.formattedSpeed.isEmpty ? "" : " · \(item.formattedSpeed)"
            return "\(pct)% · \(item.formattedProgressSize)\(speedStr)"
        case .paused:
            let pct = item.percentageInt
            return "Paused (\(pct)%) · \(item.formattedProgressSize)"
        case .verifying:
            return item.isFolder ? "Extracting folder…" : "Verifying SHA-256 checksum…"
        case .completed:
            let dev = item.deviceName.isEmpty ? "" : " · \(item.deviceName)"
            return "\(item.formattedTotalSize)\(dev)"
        case .cancelled:
            return "Cancelled"
        case .failed(let msg):
            return msg.isEmpty ? "Connection lost during transfer." : msg
        }
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

// MARK: - Phosphor Navigation Tab Icons

struct PhosphorIcons {
    static let svgs: [String: String] = [
        "device-mobile": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M176,16H80A24,24,0,0,0,56,40V216a24,24,0,0,0,24,24h96a24,24,0,0,0,24-24V40A24,24,0,0,0,176,16ZM72,64H184V192H72Zm8-32h96a8,8,0,0,1,8,8v8H72V40A8,8,0,0,1,80,32Zm96,192H80a8,8,0,0,1-8-8v-8H184v8A8,8,0,0,1,176,224Z\"/></svg>",
        "device-mobile-bold": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\"><rect x=\"64\" y=\"24\" width=\"128\" height=\"208\" rx=\"16\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/><line x1=\"64\" y1=\"64\" x2=\"192\" y2=\"64\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/><line x1=\"64\" y1=\"192\" x2=\"192\" y2=\"192\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/></svg>",
        "device-mobile-fill": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M176,16H80A24,24,0,0,0,56,40V216a24,24,0,0,0,24,24h96a24,24,0,0,0,24-24V40A24,24,0,0,0,176,16ZM80,32h96a8,8,0,0,1,8,8v8H72V40A8,8,0,0,1,80,32Zm96,192H80a8,8,0,0,1-8-8v-8H184v8A8,8,0,0,1,176,224Z\"/></svg>",
        "bell": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M221.8,175.94C216.25,166.38,208,139.33,208,104a80,80,0,1,0-160,0c0,35.34-8.26,62.38-13.81,71.94A16,16,0,0,0,48,200H88.81a40,40,0,0,0,78.38,0H208a16,16,0,0,0,13.8-24.06ZM128,216a24,24,0,0,1-22.62-16h45.24A24,24,0,0,1,128,216ZM48,184c7.7-13.24,16-43.92,16-80a64,64,0,1,1,128,0c0,36.05,8.28,66.73,16,80Z\"/></svg>",
        "bell-bold": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\"><path d=\"M96,184v8a32,32,0,0,0,64,0v-8\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/><path d=\"M56,104a72,72,0,0,1,144,0c0,35.82,8.3,56.6,14.9,68A8,8,0,0,1,208,184H48a8,8,0,0,1-6.88-12C47.71,160.6,56,139.81,56,104Z\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/></svg>",
        "bell-fill": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M221.8,175.94C216.25,166.38,208,139.33,208,104a80,80,0,1,0-160,0c0,35.34-8.26,62.38-13.81,71.94A16,16,0,0,0,48,200H88.81a40,40,0,0,0,78.38,0H208a16,16,0,0,0,13.8-24.06ZM128,216a24,24,0,0,1-22.62-16h45.24A24,24,0,0,1,128,216Z\"/></svg>",
        "paper-plane-tilt": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M227.32,28.68a16,16,0,0,0-15.66-4.08l-.15,0L19.57,82.84a16,16,0,0,0-2.49,29.8L102,154l41.3,84.87A15.86,15.86,0,0,0,157.74,248q.69,0,1.38-.06a15.88,15.88,0,0,0,14-11.51l58.2-191.94c0-.05,0-.1,0-.15A16,16,0,0,0,227.32,28.68ZM157.83,231.85l-.05.14,0-.07-40.06-82.3,48-48a8,8,0,0,0-11.31-11.31l-48,48L24.08,98.25l-.07,0,.14,0L216,40Z\"/></svg>",
        "paper-plane-tilt-bold": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\"><line x1=\"108\" y1=\"148\" x2=\"160\" y2=\"96\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/><path d=\"M223.69,42.18a8,8,0,0,0-9.87-9.87l-192,58.22a8,8,0,0,0-1.25,14.93L108,148l42.54,87.42a8,8,0,0,0,14.93-1.25Z\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/></svg>",
        "paper-plane-tilt-fill": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M231.4,44.34s0,.1,0,.15l-58.2,191.94a15.88,15.88,0,0,1-14,11.51q-.69.06-1.38.06a15.86,15.86,0,0,1-14.42-9.15L107,164.15a4,4,0,0,1,.77-4.58l57.92-57.92a8,8,0,0,0-11.31-11.31L96.43,148.26a4,4,0,0,1-4.58.77L17.08,112.64a16,16,0,0,1,2.49-29.8l191.94-58.2.15,0A16,16,0,0,1,231.4,44.34Z\"/></svg>",
        "gear-six": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M128,80a48,48,0,1,0,48,48A48.05,48.05,0,0,0,128,80Zm0,80a32,32,0,1,1,32-32A32,32,0,0,1,128,160Zm109.94-52.79a8,8,0,0,0-3.89-5.4l-29.83-17-.12-33.62a8,8,0,0,0-2.83-6.08,111.91,111.91,0,0,0-36.72-20.67,8,8,0,0,0-6.46.59L128,41.85,97.88,25a8,8,0,0,0-6.47-.6A112.1,112.1,0,0,0,54.73,45.15a8,8,0,0,0-2.83,6.07l-.15,33.65-29.83,17a8,8,0,0,0-3.89,5.4,106.47,106.47,0,0,0,0,41.56,8,8,0,0,0,3.89,5.4l29.83,17,.12,33.62a8,8,0,0,0,2.83,6.08,111.91,111.91,0,0,0,36.72,20.67,8,8,0,0,0,6.46-.59L128,214.15,158.12,231a7.91,7.91,0,0,0,3.9,1,8.09,8.09,0,0,0,2.57-.42,112.1,112.1,0,0,0,36.68-20.73,8,8,0,0,0,2.83-6.07l.15-33.65,29.83-17a8,8,0,0,0,3.89-5.4A106.47,106.47,0,0,0,237.94,107.21Zm-15,34.91-28.57,16.25a8,8,0,0,0-3,3c-.58,1-1.19,2.06-1.81,3.06a7.94,7.94,0,0,0-1.22,4.21l-.15,32.25a95.89,95.89,0,0,1-25.37,14.3L134,199.13a8,8,0,0,0-3.91-1h-.19c-1.21,0-2.43,0-3.64,0a8.08,8.08,0,0,0-4.1,1l-28.84,16.1A96,96,0,0,1,67.88,201l-.11-32.2a8,8,0,0,0-1.22-4.22c-.62-1-1.23-2-1.8-3.06a8.09,8.09,0,0,0-3-3.06l-28.6-16.29a90.49,90.49,0,0,1,0-28.26L61.67,97.63a8,8,0,0,0,3-3c.58-1,1.19-2.06,1.81-3.06a7.94,7.94,0,0,0,1.22-4.21l.15-32.25a95.89,95.89,0,0,1,25.37-14.3L122,56.87a8,8,0,0,0,4.1,1c1.21,0,2.43,0,3.64,0a8.08,8.08,0,0,0,4.1-1l28.84-16.1A96,96,0,0,1,188.12,55l.11,32.2a8,8,0,0,0,1.22,4.22c.62,1,1.23,2,1.8,3.06a8.09,8.09,0,0,0,3,3.06l28.6,16.29A90.49,90.49,0,0,1,222.9,142.12Z\"/></svg>",
        "gear-six-bold": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\"><circle cx=\"128\" cy=\"128\" r=\"40\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/><path d=\"M130.05,206.11c-1.34,0-2.69,0-4,0L94,224a104.61,104.61,0,0,1-34.11-19.2l-.12-36c-.71-1.12-1.38-2.25-2-3.41L25.9,147.24a99.15,99.15,0,0,1,0-38.46l31.84-18.1c.65-1.15,1.32-2.29,2-3.41l.16-36A104.58,104.58,0,0,1,94,32l32,17.89c1.34,0,2.69,0,4,0L162,32a104.61,104.61,0,0,1,34.11,19.2l.12,36c.71,1.12,1.38,2.25,2,3.41l31.85,18.14a99.15,99.15,0,0,1,0,38.46l-31.84,18.1c-.65,1.15-1.32,2.29-2,3.41l-.16,36A104.58,104.58,0,0,1,162,224Z\" fill=\"none\" stroke=\"black\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-width=\"24\"/></svg>",
        "gear-six-fill": "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 256 256\" fill=\"black\"><path d=\"M237.94,107.21a8,8,0,0,0-3.89-5.4l-29.83-17-.12-33.62a8,8,0,0,0-2.83-6.08,111.91,111.91,0,0,0-36.72-20.67,8,8,0,0,0-6.46.59L128,41.85,97.88,25a8,8,0,0,0-6.47-.6A111.92,111.92,0,0,0,54.73,45.15a8,8,0,0,0-2.83,6.07l-.15,33.65-29.83,17a8,8,0,0,0-3.89,5.4,106.47,106.47,0,0,0,0,41.56,8,8,0,0,0,3.89,5.4l29.83,17,.12,33.63a8,8,0,0,0,2.83,6.08,111.91,111.91,0,0,0,36.72,20.67,8,8,0,0,0,6.46-.59L128,214.15,158.12,231a7.91,7.91,0,0,0,3.9,1,8.09,8.09,0,0,0,2.57-.42,112.1,112.1,0,0,0,36.68-20.73,8,8,0,0,0,2.83-6.07l.15-33.65,29.83-17a8,8,0,0,0,3.89-5.4A106.47,106.47,0,0,0,237.94,107.21ZM128,168a40,40,0,1,1,40-40A40,40,0,0,1,128,168Z\"/></svg>"
    ]

    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let svg = svgs[name], let data = svg.data(using: .utf8), let img = NSImage(data: data) else {
            return nil
        }
        img.isTemplate = true
        cache[name] = img
        return img
    }
}

struct PhosphorIconView: View {
    let name: String
    var size: CGFloat = 15

    var body: some View {
        if let img = PhosphorIcons.image(named: name) {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Main Menu Bar View

struct MacSaveLocationRow: View {
    @ObservedObject var fileTransferManager: BridgeFileTransferManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Location to Save Files")
                    .font(.custom("PlusJakartaSans-Medium", size: 13))
                    .foregroundColor(BridgeColors.text)
                Text(fileTransferManager.saveLocationDisplayName)
                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                    .foregroundColor(BridgeColors.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 6) {
                if fileTransferManager.hasCustomSaveLocation {
                    Button(action: {
                        fileTransferManager.resetSaveLocation()
                    }, label: {
                        Text("Reset")
                            .font(.custom("PlusJakartaSans-Medium", size: 11))
                            .foregroundColor(BridgeColors.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(BridgeColors.line)
                            .cornerRadius(6)
                    })
                    .buttonStyle(PlainButtonStyle())
                }

                Button(action: {
                    fileTransferManager.chooseSaveLocation()
                }, label: {
                    Text("Change")
                        .font(.custom("PlusJakartaSans-Medium", size: 11))
                        .foregroundColor(BridgeColors.lime)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(BridgeColors.lime.opacity(0.12))
                        .cornerRadius(6)
                })
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

struct BridgeMenuView: View {
    @ObservedObject var model: BridgeModel
    @ObservedObject var notifManager: BridgeNotificationManager = BridgeNotificationManager.shared
    @ObservedObject var fileTransferManager: BridgeFileTransferManager = BridgeFileTransferManager.shared
    @ObservedObject var axObserver: AXNotificationObserver = AXNotificationObserver.shared

    private var isPairedOrConnected: Bool {
        model.isConnected || model.pairedDevice != nil
    }

    private var activeFileTransferCount: Int {
        fileTransferManager.transfers.filter { $0.status.isActive }.count
    }

    private var notificationCardsList: some View {
        VStack(spacing: 8) {
            ForEach(notifManager.activeNotifications) { notif in
                NotificationCardView(notification: notif, manager: notifManager)
            }
        }
    }

    private var fileTransferCardsList: some View {
        VStack(spacing: 8) {
            ForEach(fileTransferManager.transfers) { item in
                FileTransferCardView(item: item, manager: fileTransferManager)
            }
        }
    }

    @ViewBuilder
    private func pairingCardView(isAddingAnotherPhone: Bool) -> some View {
        let qrSize: CGFloat = isAddingAnotherPhone ? 148 : 176
        VStack(spacing: isAddingAnotherPhone ? 10 : 12) {
            Text(isAddingAnotherPhone ? "ADD ANOTHER PHONE" : "PAIR YOUR PHONE")
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
                        .padding(isAddingAnotherPhone ? 10 : 12)
                        .frame(width: qrSize, height: qrSize)
                }
            }

            VStack(spacing: 3) {
                Text("Open Bridge on your Android phone and scan this QR code to connect.")
                    .font(.custom("PlusJakartaSans-Regular", size: 12.5))
                    .foregroundColor(BridgeColors.soft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if isAddingAnotherPhone {
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
                        .font(.custom("DMMono-Medium", size: isAddingAnotherPhone ? 27 : 30))
                        .foregroundColor(BridgeColors.lime)
                        .kerning(1.8)

                    Button(action: {
                        model.copyPairingCode()
                    }) {
                        Text(model.copiedNotice ? "Copied" : "Copy")
                            .font(.custom("PlusJakartaSans-Medium", size: 13.5))
                            .foregroundColor(model.copiedNotice ? BridgeColors.ink : BridgeColors.text)
                            .frame(minWidth: 80, minHeight: isAddingAnotherPhone ? 38 : 44)
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
        .padding(isAddingAnotherPhone ? 15 : 18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(BridgeColors.panel)
        )
    }

    @ViewBuilder
    private var deviceCardsSection: some View {
        VStack(spacing: 10) {
            if !model.connectedDevicesList.isEmpty {
                ForEach(model.connectedDevicesList) { device in
                    VStack(spacing: 16) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(device.isConnected ? BridgeColors.lime : BridgeColors.line)
                                    .frame(width: 40, height: 40)

                                Image(systemName: "iphone")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(device.isConnected ? BridgeColors.ink : BridgeColors.soft)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(formatDisplayDeviceName(device.name))
                                    .font(.custom("PlusJakartaSans-Medium", size: 14))
                                    .foregroundColor(BridgeColors.text)
                                    .kerning(-0.15)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: false, vertical: true)

                                if device.isConnected {
                                    Text("Connected · Same Wi-Fi")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Disconnected · Tap Connect on phone")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            Spacer(minLength: 8)

                            BatteryRingView(
                                level: device.batteryLevel,
                                isCharging: device.isCharging,
                                isStale: model.isBatteryStale(device)
                            )
                        }

                        // 4-Tile Quick Panel: Sound (Normal -> Vibrate -> Silent), Do Not Disturb, Mirror Phone, Ring the Phone
                        HStack(alignment: .top, spacing: 8) {
                            // 1. Sound (Normal -> Vibrate -> Silent -> Normal)
                            let soundFill: Color = {
                                switch device.ringerMode {
                                case .normal: return BridgeColors.activeTab
                                case .vibrate: return BridgeColors.amber.opacity(0.16)
                                case .silent: return BridgeColors.coral.opacity(0.12)
                                }
                            }()
                            let soundBorder: Color = {
                                switch device.ringerMode {
                                case .normal: return BridgeColors.lime.opacity(0.35)
                                case .vibrate: return BridgeColors.amber.opacity(0.45)
                                case .silent: return BridgeColors.coral.opacity(0.42)
                                }
                            }()
                            let soundIconColor: Color = {
                                switch device.ringerMode {
                                case .normal: return BridgeColors.lime
                                case .vibrate: return BridgeColors.amber
                                case .silent: return BridgeColors.coral
                                }
                            }()
                            QuickControlTileButton(
                                iconName: device.ringerMode.symbolName,
                                label: device.ringerMode.displayName,
                                fillColor: soundFill,
                                borderColor: soundBorder,
                                iconColor: soundIconColor,
                                labelColor: BridgeColors.soft,
                                helpText: "Android Sound Mode (Sound → Vibrate → Silent)",
                                isPending: model.pendingRingerDeviceIds.contains(device.id)
                            ) {
                                model.cycleRingerMode(for: device)
                            }

                            // 2. Do Not Disturb (Android only)
                            QuickControlTileButton(
                                iconName: device.isDndEnabled ? "moon.fill" : "minus.circle",
                                label: "Do Not\nDisturb",
                                fillColor: device.isDndEnabled ? BridgeColors.activeTab : BridgeColors.bg.opacity(0.75),
                                borderColor: device.isDndEnabled ? BridgeColors.lime.opacity(0.35) : BridgeColors.line2,
                                iconColor: device.isDndEnabled ? BridgeColors.lime : BridgeColors.soft,
                                labelColor: device.isDndEnabled ? BridgeColors.text : BridgeColors.soft,
                                helpText: device.isDndEnabled ? "Turn off Android Do Not Disturb on \(device.name)" : "Turn on Android Do Not Disturb on \(device.name)",
                                isPending: model.pendingDndDeviceIds.contains(device.id)
                            ) {
                                model.toggleDnd(for: device)
                            }

                            // 3. Mirror Phone
                            let mirrorState = model.phoneMirrorState(for: device)
                            let isMirrorActive = (mirrorState == .streaming)
                            let isMirrorPending = (mirrorState == .waitingForPhone)
                            let isMirrorHighlighted = isMirrorActive || isMirrorPending
                            QuickControlTileButton(
                                iconName: "rectangle.on.rectangle.fill",
                                label: isMirrorActive ? "Stop\nMirroring" : (isMirrorPending ? "Starting\nMirror…" : "Mirror\nPhone"),
                                fillColor: isMirrorHighlighted ? BridgeColors.activeTab : BridgeColors.bg.opacity(0.75),
                                borderColor: isMirrorHighlighted ? BridgeColors.lime.opacity(0.35) : BridgeColors.line2,
                                iconColor: isMirrorHighlighted ? BridgeColors.lime : BridgeColors.soft,
                                labelColor: isMirrorHighlighted ? BridgeColors.text : BridgeColors.soft,
                                helpText: isMirrorActive ? "Stop mirroring \(device.name)" : "Mirror \(device.name) screen on this Mac",
                                isPending: isMirrorPending
                            ) {
                                model.togglePhoneMirroring(for: device)
                            }

                            // 4. Ring the Phone (temporary Find My Phone action)
                            QuickControlTileButton(
                                iconName: device.isRingingPhone ? "bell.and.waves.left.and.right.fill" : "bell.fill",
                                label: device.isRingingPhone ? "Stop\nRinging" : "Ring the\nPhone",
                                fillColor: device.isRingingPhone ? BridgeColors.coral.opacity(0.16) : BridgeColors.bg.opacity(0.75),
                                borderColor: device.isRingingPhone ? BridgeColors.coral.opacity(0.55) : BridgeColors.line2,
                                iconColor: device.isRingingPhone ? BridgeColors.coral : BridgeColors.soft,
                                labelColor: device.isRingingPhone ? BridgeColors.coral : BridgeColors.soft,
                                helpText: device.isRingingPhone ? "Stop ringing \(device.name)" : "Ring \(device.name) until stopped",
                                isPending: model.pendingRingDeviceIds.contains(device.id)
                            ) {
                                model.toggleRingPhone(for: device)
                            }
                        }

                        if let errHint = model.controlErrorHints[device.id] {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(BridgeColors.coral)
                                    .frame(width: 6, height: 6)
                                Text(errHint)
                                    .font(.custom("PlusJakartaSans-Regular", size: 11))
                                    .foregroundColor(BridgeColors.coral)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if case .error(let mirrorErr) = model.phoneMirrorState(for: device) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(BridgeColors.coral)
                                    .frame(width: 6, height: 6)
                                Text(mirrorErr)
                                    .font(.custom("PlusJakartaSans-Regular", size: 11))
                                    .foregroundColor(BridgeColors.coral)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if model.dndHintDeviceIds.contains(device.id) && !device.hasDndPermission {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(BridgeColors.coral)
                                    .frame(width: 6, height: 6)
                                Text("Grant Do Not Disturb access in Bridge on \(device.name).")
                                    .font(.custom("PlusJakartaSans-Regular", size: 11))
                                    .foregroundColor(BridgeColors.coral)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let media = device.mediaInfo, media.isActive {
                            NowPlayingCardView(device: device, media: media, model: model)
                        }

                        Divider().background(BridgeColors.line.opacity(0.6))

                        HStack(spacing: 8) {
                            Button(action: {
                                model.disconnect(deviceId: device.id)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "power")
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text("Disconnect")
                                        .font(.custom("PlusJakartaSans-Medium", size: 12.5))
                                }
                                .foregroundColor(BridgeColors.soft)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(BridgeColors.bg.opacity(0.7))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(BridgeColors.line2, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Disconnect \(device.name) without unpairing")

                            Button(action: {
                                model.deviceToUnpair = device
                                model.showUnpairConfirmation = true
                            }) {
                                HStack(spacing: 6) {
                                    UnlinkIconShape()
                                        .stroke(
                                            BridgeColors.coral,
                                            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                                        )
                                        .frame(width: 12.5, height: 12.5)
                                    Text("Unpair")
                                        .font(.custom("PlusJakartaSans-Medium", size: 12.5))
                                }
                                .foregroundColor(BridgeColors.coral)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(BridgeColors.coral.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(BridgeColors.coral.opacity(0.38), lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Unpair \(device.name)")
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(BridgeColors.panel)
                    )
                }
            } else {
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
                        Text(formatDisplayDeviceName(model.connectedDevice ?? model.pairedDevice ?? "Phone"))
                            .font(.custom("PlusJakartaSans-Medium", size: 14))
                            .foregroundColor(BridgeColors.text)
                            .kerning(-0.15)
                            .lineLimit(1)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(model.isConnected ? "Connected · Same Wi-Fi" : "Disconnected · Tap Connect in Bridge on your phone")
                            .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 6)

                    Button(action: {
                        model.deviceToUnpair = nil
                        model.showUnpairConfirmation = true
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
            }
        }
    }

    private var addAnotherPhoneButton: some View {
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
                    .fill(BridgeColors.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(BridgeColors.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var settingsSectionsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section 1: Synced Settings
            VStack(alignment: .leading, spacing: 6) {
                Text("SYNCED SETTINGS")
                    .font(.custom("DMMono-Regular", size: 10.5))
                    .foregroundColor(BridgeColors.muted)
                    .kerning(1.0)
                    .padding(.leading, 2)

                VStack(alignment: .leading, spacing: 10) {
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

                    Divider().background(BridgeColors.line.opacity(0.6))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Accept Incoming Files")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))
                                .foregroundColor(BridgeColors.text)
                            Text("Automatically accept incoming files without prompting.")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $fileTransferManager.autoAcceptIncomingFiles)
                            .labelsHidden()
                            .toggleStyle(BridgeSwitchToggleStyle())
                    }

                    Divider().background(BridgeColors.line.opacity(0.6))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Calls on Mac")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))
                                .foregroundColor(BridgeColors.text)
                            Text("Show incoming phone calls on your Mac so you can answer or manage them here.")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $notifManager.isCallsOnMacEnabled)
                            .labelsHidden()
                            .toggleStyle(BridgeSwitchToggleStyle())
                    }
                }
                .padding(13)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(BridgeColors.panel)
                )
            }

            // Section 2: Mac-Only Settings
            VStack(alignment: .leading, spacing: 6) {
                Text("MAC ONLY")
                    .font(.custom("DMMono-Regular", size: 10.5))
                    .foregroundColor(BridgeColors.muted)
                    .kerning(1.0)
                    .padding(.leading, 2)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at Login")
                                    .font(.custom("PlusJakartaSans-Medium", size: 13))
                                    .foregroundColor(BridgeColors.text)
                                Text("Start Bridge automatically when you log in to your Mac.")
                                    .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                    .foregroundColor(BridgeColors.muted)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { model.isLaunchAtLoginEnabled },
                                set: { model.setLaunchAtLogin(enabled: $0) }
                            ))
                            .labelsHidden()
                            .toggleStyle(BridgeSwitchToggleStyle())
                        }

                        if model.launchAtLoginRequiresApproval {
                            Button(action: {
                                model.openLoginItemsSettings()
                            }) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(BridgeColors.coral)
                                        .frame(width: 6, height: 6)
                                    Text("Allow Bridge in System Settings → Login Items")
                                        .font(.custom("PlusJakartaSans-Medium", size: 11.5))
                                        .foregroundColor(BridgeColors.coral)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else if let errorText = model.launchAtLoginError {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(BridgeColors.coral)
                                    .frame(width: 6, height: 6)
                                Text(errorText)
                                    .font(.custom("PlusJakartaSans-Medium", size: 11.5))
                                    .foregroundColor(BridgeColors.coral)
                                Spacer()
                                Button(action: {
                                    model.openLoginItemsSettings()
                                }) {
                                    Text("Login Items")
                                        .font(.custom("PlusJakartaSans-SemiBold", size: 11))
                                        .foregroundColor(BridgeColors.lime)
                                        .underline()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider().background(BridgeColors.line.opacity(0.6))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Pause Mac Media")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))
                                .foregroundColor(BridgeColors.text)
                            Text("Pause music and videos on your Mac when a phone call arrives.")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $model.isAutoPauseMacMediaEnabled)
                            .labelsHidden()
                            .toggleStyle(BridgeSwitchToggleStyle())
                            .disabled(!model.isAnyGetCallOnMacEnabled)
                    }
                    .opacity(model.isAnyGetCallOnMacEnabled ? 1.0 : 0.45)

                    Divider().background(BridgeColors.line.opacity(0.6))

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Low Battery Alert")
                                .font(.custom("PlusJakartaSans-Medium", size: 13))
                                .foregroundColor(BridgeColors.text)
                            Text("Notify when your phone battery drops to 15% or below.")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                        }
                        Spacer()
                        Toggle("", isOn: $model.isLowBatteryAlertEnabled)
                            .labelsHidden()
                            .toggleStyle(BridgeSwitchToggleStyle())
                    }

                    Divider().background(BridgeColors.line.opacity(0.6))

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

                    Divider().background(BridgeColors.line.opacity(0.6))

                    MacSaveLocationRow(fileTransferManager: fileTransferManager)

                    if !notifManager.isSystemNotificationAllowed {
                        Divider().background(BridgeColors.line.opacity(0.6))

                        Button(action: {
                            notifManager.openNotificationSettings()
                        }) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bell.badge.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(BridgeColors.coral)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Banner Notifications")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text("Allow Bridge in System Settings → Notifications.")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }

                                Spacer()

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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !axObserver.isAccessibilityTrusted {
                        Divider().background(BridgeColors.line.opacity(0.6))

                        Button(action: {
                            axObserver.promptAccessibilityPermissions()
                        }) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(BridgeColors.coral)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Accessibility Permission")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text("Grant Accessibility permission in System Settings.")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }

                                Spacer()

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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !fileTransferManager.isFilesAndFoldersAllowed {
                        Divider().background(BridgeColors.line.opacity(0.6))

                        Button(action: {
                            fileTransferManager.openFilesAndFoldersSettings()
                        }) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "folder.badge.gearshape")
                                    .font(.system(size: 13))
                                    .foregroundColor(BridgeColors.coral)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Mac Files & Folders Access")
                                        .font(.custom("PlusJakartaSans-Medium", size: 13))
                                        .foregroundColor(BridgeColors.text)
                                    Text("Allow Bridge to send files from your Documents folder.")
                                        .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }

                                Spacer()

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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(13)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(BridgeColors.panel)
                )
            }
        }
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

            if isPairedOrConnected {
                // Tab Switcher (Icon-only with tooltips): [Devices]  [Notifications]  [Transfer]  [Settings]
                HStack(spacing: 6) {
                    Button(action: {
                        if model.selectedTab != .devices {
                            model.selectedTab = .devices
                        }
                    }) {
                        ZStack(alignment: .topTrailing) {
                            PhosphorIconView(name: "device-mobile-bold", size: 16)

                            if model.isConnected {
                                Circle()
                                    .fill(BridgeColors.lime)
                                    .frame(width: 6, height: 6)
                                    .offset(x: 7, y: -2)
                            }
                        }
                        .foregroundColor(model.selectedTab == .devices ? BridgeColors.lime : BridgeColors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.selectedTab == .devices ? BridgeColors.activeTab : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Devices")

                    Button(action: {
                        if model.selectedTab != .notifications {
                            model.selectedTab = .notifications
                        }
                    }) {
                        ZStack(alignment: .topTrailing) {
                            PhosphorIconView(name: "bell-bold", size: 16)

                            if !notifManager.activeNotifications.isEmpty {
                                Text("\(notifManager.activeNotifications.count)")
                                    .font(.custom("DMMono-Bold", size: 9))
                                    .foregroundColor(BridgeColors.ink)
                                    .padding(.horizontal, 4)
                                    .frame(height: 13)
                                    .background(
                                        Capsule()
                                            .fill(BridgeColors.lime)
                                    )
                                    .offset(x: 10, y: -6)
                            }
                        }
                        .foregroundColor(model.selectedTab == .notifications ? BridgeColors.lime : BridgeColors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.selectedTab == .notifications ? BridgeColors.activeTab : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(notifManager.activeNotifications.isEmpty ? "Notifications" : "Notifications (\(notifManager.activeNotifications.count))")

                    Button(action: {
                        if model.selectedTab != .files {
                            model.selectedTab = .files
                        }
                    }) {
                        ZStack(alignment: .topTrailing) {
                            PhosphorIconView(name: "paper-plane-tilt-bold", size: 16)

                            if activeFileTransferCount > 0 {
                                Text("\(activeFileTransferCount)")
                                    .font(.custom("DMMono-Bold", size: 9))
                                    .foregroundColor(BridgeColors.ink)
                                    .padding(.horizontal, 4)
                                    .frame(height: 13)
                                    .background(
                                        Capsule()
                                            .fill(BridgeColors.lime)
                                    )
                                    .offset(x: 10, y: -6)
                            }
                        }
                        .foregroundColor(model.selectedTab == .files ? BridgeColors.lime : BridgeColors.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(model.selectedTab == .files ? BridgeColors.activeTab : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(activeFileTransferCount == 0 ? "Transfer" : "Transfer (\(activeFileTransferCount) active)")

                    Button(action: {
                        if model.selectedTab != .settings {
                            model.selectedTab = .settings
                        }
                    }) {
                        PhosphorIconView(name: "gear-six-bold", size: 16)
                            .foregroundColor(model.selectedTab == .settings ? BridgeColors.lime : BridgeColors.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(model.selectedTab == .settings ? BridgeColors.activeTab : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
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

                // Tab 1: Devices
                if model.selectedTab == .devices {
                    if model.showUnpairConfirmation {
                        // Unpair Confirmation Dialog
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(BridgeColors.coral)

                                Text("Unpair \(model.deviceToUnpair?.name ?? model.connectedDevice ?? model.pairedDevice ?? "this phone")?")
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 13))
                                    .foregroundColor(BridgeColors.text)
                            }

                            Text("This will remove the pairing between this phone and your Mac. You'll need to pair them again to reconnect.")
                                .font(.custom("PlusJakartaSans-Regular", size: 11.5))
                                .foregroundColor(BridgeColors.muted)
                                .lineSpacing(2)

                            HStack(spacing: 8) {
                                Spacer()

                                Button(action: {
                                    model.showUnpairConfirmation = false
                                    model.deviceToUnpair = nil
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
                                    let devId = model.deviceToUnpair?.id
                                    model.showUnpairConfirmation = false
                                    model.unpair(deviceId: devId)
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
                    } else if model.showPairingSection {
                        VStack(spacing: 10) {
                            addAnotherPhoneButton
                            pairingCardView(isAddingAnotherPhone: true)
                        }
                    } else {
                        let hasManyDevices = model.connectedDevicesList.count > 1
                        let screenHeight = NSScreen.main?.visibleFrame.height ?? 860
                        let deviceScrollHeight = max(280, min(460, floor(screenHeight - 280)))

                        VStack(spacing: 10) {
                            if hasManyDevices {
                                ScrollView(.vertical, showsIndicators: true) {
                                    deviceCardsSection
                                        .padding(.trailing, 2)
                                }
                                .frame(height: deviceScrollHeight)
                            } else {
                                deviceCardsSection
                            }

                            addAnotherPhoneButton
                        }
                    }
                }

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

                                ViewThatFits(in: .vertical) {
                                    notificationCardsList

                                    ScrollView(.vertical, showsIndicators: true) {
                                        notificationCardsList
                                            .padding(.trailing, 2)
                                    }
                                    .frame(height: 280)
                                }
                                .frame(maxHeight: 280)
                            }
                        }
                    }
                }

                // Tab 3: Files
                if model.selectedTab == .files {
                    VStack(alignment: .leading, spacing: 10) {
                        // Target Device Selector Pill
                        HStack(spacing: 8) {
                            Text("SEND TO")
                                .font(.custom("DMMono-Regular", size: 10))
                                .foregroundColor(BridgeColors.muted)
                                .kerning(0.9)

                            if model.connectedDevicesList.isEmpty {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(BridgeColors.muted)
                                        .frame(width: 6, height: 6)
                                    Text(model.pairedDevice ?? "Offline")
                                        .font(.custom("PlusJakartaSans-Medium", size: 11.5))
                                        .foregroundColor(BridgeColors.muted)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(
                                    Capsule()
                                        .fill(BridgeColors.panel)
                                )
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(model.connectedDevicesList) { dev in
                                            let isSelected = (model.selectedTargetDeviceId == dev.id) ||
                                                (model.selectedTargetDeviceId == nil && model.connectedDevicesList.first?.id == dev.id)
                                            Button(action: {
                                                model.selectedTargetDeviceId = dev.id
                                            }) {
                                                HStack(spacing: 5) {
                                                    Image(systemName: "iphone")
                                                        .font(.system(size: 10.5, weight: .semibold))
                                                    Text(dev.name)
                                                        .font(.custom("PlusJakartaSans-SemiBold", size: 11.5))
                                                        .lineLimit(1)
                                                }
                                                .foregroundColor(isSelected ? BridgeColors.ink : BridgeColors.soft)
                                                .padding(.horizontal, 10)
                                                .frame(height: 24)
                                                .background(
                                                    Capsule()
                                                        .fill(isSelected ? BridgeColors.lime : BridgeColors.panel)
                                                )
                                                .overlay(
                                                    Capsule()
                                                        .stroke(isSelected ? Color.clear : BridgeColors.line2, lineWidth: 1)
                                                )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }

                            Spacer(minLength: 0)
                        }

                        // Drag & Drop Zone / Browse Button
                        Button(action: {
                            if model.isConnected {
                                model.selectFilesToSend()
                            }
                        }) {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(model.isDropTargeted ? BridgeColors.lime.opacity(0.2) : BridgeColors.bg)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .stroke(model.isDropTargeted ? BridgeColors.lime : BridgeColors.line2, lineWidth: 1)
                                        )

                                    Image(systemName: "arrow.up.doc.fill")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(model.isConnected ? BridgeColors.lime : BridgeColors.muted)
                                }

                                Text(model.isDropTargeted ? "Drop to send to \(model.targetDeviceDisplayName)" : (model.isConnected ? "Drop files or folders here or click to browse" : "Connect your phone to transfer files"))
                                    .font(.custom("PlusJakartaSans-SemiBold", size: 12.5))
                                    .foregroundColor(model.isDropTargeted ? BridgeColors.lime : (model.isConnected ? BridgeColors.text : BridgeColors.muted))

                                Text(model.isDropTargeted ? "Release to begin high-speed transfer" : "Direct local Wi-Fi / Hotspot stream · No size limit")
                                    .font(.custom("PlusJakartaSans-Regular", size: 11))
                                    .foregroundColor(model.isDropTargeted ? BridgeColors.soft : BridgeColors.muted)
                            }
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(model.isDropTargeted ? BridgeColors.lime.opacity(0.08) : BridgeColors.panel.opacity(0.75))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(
                                        model.isDropTargeted ? BridgeColors.lime : BridgeColors.line2,
                                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                                    )
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.isConnected)
                        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
                            guard model.isConnected else { return false }
                            var collectedURLs: [URL] = []
                            let group = DispatchGroup()
                            let lock = NSLock()

                            for provider in providers {
                                if provider.canLoadObject(ofClass: NSURL.self) {
                                    group.enter()
                                    _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                                        defer { group.leave() }
                                        if let url = object as? URL {
                                            lock.lock()
                                            collectedURLs.append(url)
                                            lock.unlock()
                                        }
                                    }
                                }
                            }

                            group.notify(queue: .main) {
                                if !collectedURLs.isEmpty {
                                    model.sendFiles(collectedURLs)
                                }
                            }
                            return true
                        }

                        // Transfers List
                        if !fileTransferManager.transfers.isEmpty {
                            HStack {
                                Text("TRANSFERS")
                                    .font(.custom("DMMono-Regular", size: 10.5))
                                    .foregroundColor(BridgeColors.muted)
                                    .kerning(1.0)

                                Spacer()

                                if fileTransferManager.transfers.contains(where: { $0.status == .completed }) {
                                    Button(action: {
                                        fileTransferManager.clearCompletedTransfers()
                                    }) {
                                        Text("Clear completed")
                                            .font(.custom("PlusJakartaSans-Medium", size: 11.5))
                                            .foregroundColor(BridgeColors.coral)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 4)

                            ViewThatFits(in: .vertical) {
                                fileTransferCardsList

                                ScrollView(.vertical, showsIndicators: true) {
                                    fileTransferCardsList
                                        .padding(.trailing, 2)
                                }
                                .frame(height: 220)
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                }

                // Tab 4: Settings
                if model.selectedTab == .settings {
                    ViewThatFits(in: .vertical) {
                        settingsSectionsView

                        ScrollView(.vertical, showsIndicators: true) {
                            settingsSectionsView
                                .padding(.trailing, 2)
                        }
                        .frame(height: 440)
                    }
                    .frame(maxHeight: 440)
                }
            }

            // Pairing Card when NOT paired/connected (Adding another phone renders inside the scrollable Devices tab)
            if !isPairedOrConnected {
                pairingCardView(isAddingAnotherPhone: false)
            }

            // Footer Bar
            HStack {
                MaskedIpToggleView(
                    prefix: "",
                    ip: model.localIp,
                    suffix: ":\(String(model.port))",
                    isRevealed: model.isLocalIpRevealed,
                    fontName: "DMMono-Regular",
                    onToggle: {
                        model.isLocalIpRevealed.toggle()
                    }
                )

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
            model.refreshLaunchAtLoginStatus()
        }
    }
}
