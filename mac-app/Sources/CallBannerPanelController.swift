import AppKit
import SwiftUI

private final class CallBannerClock: ObservableObject {
    @Published var now: Date = Date()
    private var timer: Timer?

    func start() {
        now = Date()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.now = Date()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

private struct NativeNotificationMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .popover
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

private struct IncomingCallBannerView: View {
    let call: IncomingCallInfo
    @ObservedObject var clock: CallBannerClock
    let onAnswer: () -> Void
    let onDecline: () -> Void
    let onSilence: () -> Void
    let onMute: () -> Void
    let onDismiss: () -> Void

    private var isRinging: Bool {
        call.state == "ringing"
    }

    private var subtitleText: String {
        let device = formatDisplayDeviceName(call.deviceName)
        let trimmedApp = call.appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerApp = trimmedApp.lowercased()
        let isDefaultPhoneApp = trimmedApp.isEmpty || lowerApp == "phone" || lowerApp == "call"

        if isRinging {
            if isDefaultPhoneApp {
                return "Incoming Call · \(device)"
            }
            return "\(trimmedApp) · \(device)"
        } else {
            let duration = call.formattedDuration(at: clock.now) ?? "00:00"
            if isDefaultPhoneApp {
                return call.isMuted ? "\(duration) · Active Call (Muted) · \(device)" : "\(duration) · Active Call · \(device)"
            }
            return call.isMuted ? "\(duration) · \(trimmedApp) (Muted) · \(device)" : "\(duration) · \(trimmedApp) · \(device)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    if let icon = call.appIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(nsColor: .systemGreen))
                            .frame(width: 38, height: 38)
                            .overlay(
                                Image(systemName: isRinging ? "phone.arrow.down.left.fill" : "phone.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(call.callerName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(subtitleText)
                        .font(.system(size: 11.5, weight: .regular))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss notification")
            }

            HStack(spacing: 8) {
                if isRinging {
                    if call.canAnswer {
                        Button(action: onAnswer) {
                            HStack(spacing: 5) {
                                Image(systemName: "phone.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Accept")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .systemGreen))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if call.canDecline {
                        Button(action: onDecline) {
                            HStack(spacing: 5) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Decline")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .systemRed))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: onSilence) {
                        HStack(spacing: 4) {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Silence")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.10))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onMute) {
                        HStack(spacing: 5) {
                            Image(systemName: call.isMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(call.isMuted ? "Muted" : "Mute")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(call.isMuted ? Color(nsColor: .systemOrange) : .primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(call.isMuted ? Color(nsColor: .systemOrange).opacity(0.22) : Color.primary.opacity(0.10))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if call.canDecline {
                        Button(action: onDecline) {
                            HStack(spacing: 5) {
                                Image(systemName: "phone.down.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("End Call")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .systemRed))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 344)
        .background(NativeNotificationMaterialView())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.16), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 5)
        .padding(8)
    }
}

/// Manages a non-activating floating NSPanel banner in the top-right screen corner
/// for live incoming and active phone calls, styled to match native macOS notifications.
final class CallBannerPanelController {
    static let shared = CallBannerPanelController()

    private var panel: NSPanel?
    private var currentCallId: String?
    private let clock = CallBannerClock()

    private init() {}

    func show(call: IncomingCallInfo, model: BridgeModel) {
        DispatchQueue.main.async { [weak self, weak model] in
            guard let self = self, let model = model else { return }
            self.currentCallId = call.callId

            if call.state == "active" {
                self.clock.start()
            } else {
                self.clock.stop()
            }

            let rootView = IncomingCallBannerView(
                call: call,
                clock: self.clock,
                onAnswer: { [weak model] in
                    model?.answerCall(call)
                },
                onDecline: { [weak model] in
                    model?.declineCall(call)
                },
                onSilence: { [weak model] in
                    model?.silenceCall(call)
                },
                onMute: { [weak model] in
                    model?.muteCall(call)
                },
                onDismiss: { [weak model] in
                    model?.dismissCallBanner()
                }
            )

            let hosting = NSHostingController(rootView: rootView)
            hosting.view.layoutSubtreeIfNeeded()
            let size = hosting.view.fittingSize

            let activePanel: NSPanel
            if let existing = self.panel {
                existing.contentViewController = hosting
                activePanel = existing
            } else {
                let p = NSPanel(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                p.level = .floating
                p.isFloatingPanel = true
                p.hidesOnDeactivate = false
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = false
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                p.contentViewController = hosting
                self.panel = p
                activePanel = p
            }

            let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let origin = NSPoint(
                x: screenFrame.maxX - size.width - 10,
                y: screenFrame.maxY - size.height - 8
            )
            activePanel.setFrame(NSRect(origin: origin, size: size), display: true)
            activePanel.orderFrontRegardless()
        }
    }

    func hide(callId: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let filterId = callId, self.currentCallId != filterId {
                return
            }
            self.currentCallId = nil
            self.clock.stop()
            self.panel?.orderOut(nil)
        }
    }
}
