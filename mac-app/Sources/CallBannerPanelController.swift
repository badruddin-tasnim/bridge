import AppKit
import SwiftUI

private struct IncomingCallBannerView: View {
    let call: IncomingCallInfo
    let onAnswer: () -> Void
    let onDecline: () -> Void
    let onSilence: () -> Void
    let onDismiss: () -> Void

    private var isRinging: Bool {
        call.state == "ringing"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isRinging ? BridgeColors.lime : BridgeColors.activeTab)
                        .frame(width: 42, height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(BridgeColors.lime.opacity(isRinging ? 0 : 0.45), lineWidth: 1)
                        )

                    if let icon = call.appIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: isRinging ? "phone.arrow.down.left.fill" : "phone.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(isRinging ? BridgeColors.ink : BridgeColors.lime)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isRinging ? "INCOMING CALL" : "ON CALL")
                            .font(.custom("DMMono-Medium", size: 9.5))
                            .foregroundColor(BridgeColors.lime)
                            .kerning(1.0)

                        Text("· \(call.deviceName)")
                            .font(.custom("PlusJakartaSans-Regular", size: 11))
                            .foregroundColor(BridgeColors.muted)
                            .lineLimit(1)
                    }

                    Text(call.callerName)
                        .font(.custom("PlusJakartaSans-SemiBold", size: 14.5))
                        .foregroundColor(BridgeColors.text)
                        .lineLimit(1)

                    if !call.appName.isEmpty {
                        Text(call.appName)
                            .font(.custom("PlusJakartaSans-Regular", size: 11))
                            .foregroundColor(BridgeColors.soft)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(BridgeColors.muted)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(BridgeColors.panel)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss banner")
            }

            HStack(spacing: 8) {
                if isRinging && call.canAnswer {
                    Button(action: onAnswer) {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text("Answer")
                                .font(.custom("PlusJakartaSans-SemiBold", size: 12.5))
                        }
                        .foregroundColor(BridgeColors.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(BridgeColors.lime)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if call.canDecline {
                    Button(action: onDecline) {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(isRinging ? "Decline" : "End Call")
                                .font(.custom("PlusJakartaSans-SemiBold", size: 12.5))
                        }
                        .foregroundColor(BridgeColors.coral)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(BridgeColors.coral.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(BridgeColors.coral.opacity(0.42), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isRinging {
                    Button(action: onSilence) {
                        HStack(spacing: 5) {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Silence")
                                .font(.custom("PlusJakartaSans-Medium", size: 12))
                        }
                        .foregroundColor(BridgeColors.soft)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(BridgeColors.panel)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(BridgeColors.line2, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(BridgeColors.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(BridgeColors.line2, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 8)
        .padding(8)
    }
}

/// Manages a non-activating floating NSPanel banner in the top-right screen corner
/// for live incoming and active phone calls.
final class CallBannerPanelController {
    static let shared = CallBannerPanelController()

    private var panel: NSPanel?
    private var currentCallId: String?

    private init() {}

    func show(call: IncomingCallInfo, model: BridgeModel) {
        DispatchQueue.main.async { [weak self, weak model] in
            guard let self = self, let model = model else { return }
            self.currentCallId = call.callId

            let rootView = IncomingCallBannerView(
                call: call,
                onAnswer: { [weak model] in
                    model?.answerCall(call)
                },
                onDecline: { [weak model] in
                    model?.declineCall(call)
                },
                onSilence: { [weak model] in
                    model?.silenceCall(call)
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
            self.panel?.orderOut(nil)
        }
    }
}
