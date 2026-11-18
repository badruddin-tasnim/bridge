import AppKit
import CoreGraphics

private enum MirrorThemeColors {
    static let ink = NSColor(srgbRed: 0x0E/255.0, green: 0x0F/255.0, blue: 0x12/255.0, alpha: 1.0)
    static let bezel = NSColor(srgbRed: 0x14/255.0, green: 0x16/255.0, blue: 0x1B/255.0, alpha: 1.0)
    static let bezelBorder = NSColor(srgbRed: 0x2E/255.0, green: 0x33/255.0, blue: 0x3D/255.0, alpha: 1.0)
    static let pillBg = NSColor(srgbRed: 0x12/255.0, green: 0x14/255.0, blue: 0x18/255.0, alpha: 0.92)
    static let pillBtn = NSColor(srgbRed: 0x1E/255.0, green: 0x22/255.0, blue: 0x2A/255.0, alpha: 1.0)
    static let text = NSColor(srgbRed: 0xF4/255.0, green: 0xF5/255.0, blue: 0xF2/255.0, alpha: 1.0)
    static let soft = NSColor(srgbRed: 0xC9/255.0, green: 0xCE/255.0, blue: 0xD4/255.0, alpha: 1.0)
    static let muted = NSColor(srgbRed: 0x9B/255.0, green: 0xA3/255.0, blue: 0xAD/255.0, alpha: 1.0)
    static let lime = NSColor(srgbRed: 0xC8/255.0, green: 0xF1/255.0, blue: 0x35/255.0, alpha: 1.0)
    static let coral = NSColor(srgbRed: 0xFF/255.0, green: 0x9A/255.0, blue: 0x8A/255.0, alpha: 1.0)
    static let amber = NSColor(srgbRed: 0xF5/255.0, green: 0xA6/255.0, blue: 0x23/255.0, alpha: 1.0)
}

/// Interactive AppKit canvas that renders decoded phone frames and translates mouse/trackpad/keyboard input
/// into normalized Android Accessibility gestures, shortcuts, and IME text injection.
final class PhoneMirrorCanvasView: NSView {
    private var currentImage: CGImage?
    private var videoSize: CGSize = CGSize(width: 720, height: 1600)
    private var statusMessage: String = "Accept screen capture on your phone…"

    private var dragStartViewPoint: CGPoint?
    private var dragStartNorm: CGPoint?
    private var dragStartTimestamp: TimeInterval = 0
    private var didMoveBeyondTapThreshold = false
    private var didTriggerLongPress = false
    private var longPressWorkItem: DispatchWorkItem?

    // Trackpad & mouse-wheel swipe coalescing
    private var accumulatedScrollY: CGFloat = 0
    private var accumulatedScrollX: CGFloat = 0
    private var scrollFlushWorkItem: DispatchWorkItem?
    private var lastScrollAnchorPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var didDispatchTrackpadSwipeInPhase: Bool = false
    private var lastTrackpadSwipeSentAt: TimeInterval = 0

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { currentImage == nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MirrorThemeColors.ink.cgColor
        layer?.cornerRadius = 32
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = MirrorThemeColors.ink.cgColor
        layer?.cornerRadius = 32
        layer?.masksToBounds = true
    }

    func reset(message: String) {
        currentImage = nil
        statusMessage = message
        needsDisplay = true
    }

    func setFrameImage(_ image: CGImage, videoSize: CGSize) {
        self.currentImage = image
        self.videoSize = videoSize
        self.statusMessage = ""
        self.needsDisplay = true
    }

    func setVideoSize(_ videoSize: CGSize) {
        self.videoSize = videoSize
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(MirrorThemeColors.ink.cgColor)
        ctx.fill(bounds)

        if let image = currentImage {
            let drawRect = PhoneMirrorCoordinates.videoContentRect(in: bounds, videoSize: videoSize)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: drawRect)
            return
        }

        // Empty state while waiting for phone consent / first keyframe
        let msg = statusMessage as NSString
        let font = NSFont(name: "PlusJakartaSans-Medium", size: 13) ?? NSFont.systemFont(ofSize: 13, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: MirrorThemeColors.muted,
            .paragraphStyle: para
        ]
        let textRect = CGRect(
            x: 24,
            y: (bounds.height - 48) * 0.5,
            width: max(40, bounds.width - 48),
            height: 48
        )
        msg.draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Pointer & Touch Simulation

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)

        // Allow dragging window before stream starts
        if currentImage == nil {
            window?.performDrag(with: event)
            return
        }

        let pt = convert(event.locationInWindow, from: nil)
        guard let norm = PhoneMirrorCoordinates.normalizedPoint(
            viewPoint: pt,
            viewBounds: bounds,
            videoSize: videoSize,
            isFlipped: isFlipped
        ) else {
            return
        }

        dragStartViewPoint = pt
        dragStartNorm = norm
        dragStartTimestamp = ProcessInfo.processInfo.systemUptime
        didMoveBeyondTapThreshold = false
        didTriggerLongPress = false

        longPressWorkItem?.cancel()
        let lpItem = DispatchWorkItem { [weak self] in
            guard let self = self,
                  !self.didMoveBeyondTapThreshold,
                  let startNorm = self.dragStartNorm else {
                return
            }
            self.didTriggerLongPress = true
            PhoneMirrorManager.shared.sendLongPress(normPoint: startNorm)
        }
        longPressWorkItem = lpItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52, execute: lpItem)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPt = dragStartViewPoint else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let dist = hypot(pt.x - startPt.x, pt.y - startPt.y)
        if dist >= 10.0 && !didMoveBeyondTapThreshold {
            didMoveBeyondTapThreshold = true
            longPressWorkItem?.cancel()
            longPressWorkItem = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil

        guard let startNorm = dragStartNorm else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let elapsed = ProcessInfo.processInfo.systemUptime - dragStartTimestamp

        defer {
            dragStartViewPoint = nil
            dragStartNorm = nil
            didMoveBeyondTapThreshold = false
            didTriggerLongPress = false
        }

        if didTriggerLongPress {
            return
        }

        if didMoveBeyondTapThreshold,
           let endNorm = PhoneMirrorCoordinates.normalizedPoint(
               viewPoint: pt,
               viewBounds: bounds,
               videoSize: videoSize,
               isFlipped: isFlipped
           ) {
            let durationMs = max(100, min(220, Int(elapsed * 500.0)))
            PhoneMirrorManager.shared.sendSwipe(from: startNorm, to: endNorm, durationMs: durationMs)
        } else {
            PhoneMirrorManager.shared.sendTap(normPoint: startNorm)
        }
    }

    // MARK: - Trackpad & Scroll Wheel Swipes

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase != [] {
            return
        }

        let pt = convert(event.locationInWindow, from: nil)
        if let norm = PhoneMirrorCoordinates.normalizedPoint(
            viewPoint: pt,
            viewBounds: bounds,
            videoSize: videoSize,
            isFlipped: isFlipped
        ) {
            lastScrollAnchorPoint = norm
        }

        let isTrackpadGesture = (event.phase != [])
        if event.phase == .began {
            scrollFlushWorkItem?.cancel()
            scrollFlushWorkItem = nil
            accumulatedScrollX = 0
            accumulatedScrollY = 0
            didDispatchTrackpadSwipeInPhase = false
        }

        accumulatedScrollX += event.scrollingDeltaX
        accumulatedScrollY += event.scrollingDeltaY

        if !isTrackpadGesture {
            if scrollFlushWorkItem == nil {
                let item = DispatchWorkItem { [weak self] in
                    self?.dispatchMouseWheelSwipe()
                }
                scrollFlushWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
            }
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let mag = hypot(accumulatedScrollX, accumulatedScrollY)
        let isEnded = (event.phase == .ended || event.phase == .cancelled)

        if isEnded {
            if !didDispatchTrackpadSwipeInPhase && mag >= 8.0 {
                dispatchTrackpadSwipeIfAllowed(now: now)
            }
            accumulatedScrollX = 0
            accumulatedScrollY = 0
            didDispatchTrackpadSwipeInPhase = false
            return
        }

        if mag >= 24.0 {
            dispatchTrackpadSwipeIfAllowed(now: now)
        }
    }

    private func dispatchTrackpadSwipeIfAllowed(now: TimeInterval) {
        let dx = accumulatedScrollX
        let dy = accumulatedScrollY
        let anchor = lastScrollAnchorPoint

        if abs(dx) > abs(dy) {
            guard !didDispatchTrackpadSwipeInPhase else { return }
            didDispatchTrackpadSwipeInPhase = true
            accumulatedScrollX = 0
            accumulatedScrollY = 0
            lastTrackpadSwipeSentAt = now

            let y = min(max(anchor.y, 0.12), 0.88)
            let startX: CGFloat = (dx < 0) ? 0.78 : 0.22
            let endX: CGFloat = (dx < 0) ? 0.22 : 0.78
            PhoneMirrorManager.shared.sendSwipe(
                from: CGPoint(x: startX, y: y),
                to: CGPoint(x: endX, y: y),
                durationMs: 165
            )
        } else {
            guard (now - lastTrackpadSwipeSentAt) >= 0.21 else { return }
            lastTrackpadSwipeSentAt = now
            didDispatchTrackpadSwipeInPhase = true
            accumulatedScrollY = 0
            accumulatedScrollX = 0

            let span = min(0.55, max(0.36, abs(dy) / 160.0))
            let dir: CGFloat = dy < 0 ? -1.0 : 1.0
            let half = span * 0.5
            let clampedCenterY = min(max(anchor.y, 0.08 + half), 0.92 - half)
            let startY = clampedCenterY - dir * half
            let endY = clampedCenterY + dir * half
            let x = min(max(anchor.x, 0.10), 0.90)
            PhoneMirrorManager.shared.sendSwipe(
                from: CGPoint(x: x, y: startY),
                to: CGPoint(x: x, y: endY),
                durationMs: 165
            )
        }
    }

    private func dispatchMouseWheelSwipe() {
        scrollFlushWorkItem = nil
        let now = ProcessInfo.processInfo.systemUptime
        let dy = accumulatedScrollY
        let dx = accumulatedScrollX
        accumulatedScrollY = 0
        accumulatedScrollX = 0

        guard (now - lastTrackpadSwipeSentAt) >= 0.21 else { return }
        guard abs(dy) > 0.5 || abs(dx) > 0.5 else { return }
        lastTrackpadSwipeSentAt = now

        let anchor = lastScrollAnchorPoint
        if abs(dx) > abs(dy) {
            let y = min(max(anchor.y, 0.12), 0.88)
            let startX: CGFloat = (dx < 0) ? 0.78 : 0.22
            let endX: CGFloat = (dx < 0) ? 0.22 : 0.78
            PhoneMirrorManager.shared.sendSwipe(
                from: CGPoint(x: startX, y: y),
                to: CGPoint(x: endX, y: y),
                durationMs: 165
            )
        } else {
            let span: CGFloat = 0.36
            let dir: CGFloat = dy < 0 ? -1.0 : 1.0
            let half = span * 0.5
            let clampedCenterY = min(max(anchor.y, 0.08 + half), 0.92 - half)
            let startY = clampedCenterY - dir * half
            let endY = clampedCenterY + dir * half
            let x = min(max(anchor.x, 0.10), 0.90)
            PhoneMirrorManager.shared.sendSwipe(
                from: CGPoint(x: x, y: startY),
                to: CGPoint(x: x, y: endY),
                durationMs: 165
            )
        }
    }

    // MARK: - Keyboard & iPhone Mirroring Shortcuts Forwarding

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyEvent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKeyEvent(event) {
            super.keyDown(with: event)
        }
    }

    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "v":
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                    PhoneMirrorManager.shared.sendText(text)
                }
                return true
            case "1":
                PhoneMirrorManager.shared.sendGlobalAction("home")
                return true
            case "2":
                PhoneMirrorManager.shared.sendGlobalAction("recents")
                return true
            case "3":
                PhoneMirrorManager.shared.sendGlobalAction("back")
                return true
            case "4":
                PhoneMirrorManager.shared.sendGlobalAction("notifications")
                return true
            default:
                break
            }
        }

        switch event.keyCode {
        case 51, 117: // Delete / Backspace
            PhoneMirrorManager.shared.sendKeyAction("backspace")
            return true
        case 36, 76: // Return / Enter
            PhoneMirrorManager.shared.sendKeyAction("enter")
            return true
        case 53: // Escape -> Android Back
            PhoneMirrorManager.shared.sendGlobalAction("back")
            return true
        default:
            break
        }

        guard !flags.contains(.command), !flags.contains(.control) else {
            return false
        }

        if let chars = event.characters {
            let filtered = String(chars.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
            if !filtered.isEmpty {
                PhoneMirrorManager.shared.sendText(filtered)
                return true
            }
        }

        return false
    }
}

/// Borderless dark titanium device bezel that detects hover at the top edge to reveal the control pill
/// and allows dragging the phone anywhere on screen by grabbing its bezel.
private final class PhoneBezelView: NSView {
    var onHoverStateChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 38
        layer?.backgroundColor = MirrorThemeColors.bezel.cgColor
        layer?.borderWidth = 1.5
        layer?.borderColor = MirrorThemeColors.bezelBorder.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        evaluateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        evaluateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverStateChanged?(false)
    }

    private func evaluateHover(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let inTopZone = bounds.contains(pt) && (bounds.height - pt.y) <= 78.0
        onHoverStateChanged?(inTopZone)
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.performDrag(with: event)
    }
}

/// Floating frosted pill container that lets the user drag the window by its chrome area.
private final class HoverPillView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = MirrorThemeColors.pillBg.cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = MirrorThemeColors.bezelBorder.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.performDrag(with: event)
    }
}

private final class PhoneMirrorWindow: NSWindow {
    weak var canvasViewRef: PhoneMirrorCanvasView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let canvas = canvasViewRef, canvas.handleKeyEvent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let canvas = canvasViewRef, canvas.handleKeyEvent(event) {
            return
        }
        super.keyDown(with: event)
    }
}

/// Manages the borderless iPhone Mirroring-style floating phone window with hover-reveal controls.
final class PhoneMirrorWindowController: NSObject, NSWindowDelegate {
    static let shared = PhoneMirrorWindowController()

    private static let bezelInset: CGFloat = 6.0

    private var window: NSWindow?
    private var bezelView: PhoneBezelView?
    private var hoverPillView: HoverPillView?
    private var statusDotView: NSView?
    private var titleLabel: NSTextField?
    private var dimButton: NSButton?
    private var pinButton: NSButton?
    private var canvasView: PhoneMirrorCanvasView?

    private var currentVideoSize: CGSize = CGSize(width: 720, height: 1600)
    private var hasReceivedFirstFrame: Bool = false
    private var isMouseInHoverZone: Bool = false

    private override init() {
        super.init()
    }

    func show(deviceName: String, initialSize: CGSize, alwaysOnTop: Bool, isDimmed: Bool = true) {
        currentVideoSize = initialSize
        hasReceivedFirstFrame = false
        isMouseInHoverZone = false

        let win = ensureWindow(deviceName: deviceName, videoSize: initialSize)
        titleLabel?.stringValue = deviceName
        statusDotView?.layer?.backgroundColor = MirrorThemeColors.amber.cgColor
        canvasView?.reset(message: "Accept screen capture on \(deviceName)…")
        setAlwaysOnTop(alwaysOnTop)
        updatePinButtonAppearance(alwaysOnTop)
        updateDimButtonAppearance(isDimmed)
        refreshHoverBarVisibility(animated: false)

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let canvas = canvasView {
            win.makeFirstResponder(canvas)
        }
    }

    func updateFrame(_ image: CGImage, videoSize: CGSize) {
        let wasFirstFrame = !hasReceivedFirstFrame
        hasReceivedFirstFrame = true
        statusDotView?.layer?.backgroundColor = MirrorThemeColors.lime.cgColor

        if isOrientationChanged(from: currentVideoSize, to: videoSize) {
            updateStreamSize(videoSize)
        } else {
            currentVideoSize = videoSize
        }
        canvasView?.setFrameImage(image, videoSize: videoSize)

        if wasFirstFrame {
            refreshHoverBarVisibility(animated: true)
        }
    }

    func updateStreamSize(_ videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let oldAspect = currentVideoSize.width / max(1, currentVideoSize.height)
        let newAspect = videoSize.width / max(1, videoSize.height)
        let aspectChanged = isOrientationChanged(from: currentVideoSize, to: videoSize) || abs(oldAspect - newAspect) > 0.02
        currentVideoSize = videoSize
        canvasView?.setVideoSize(videoSize)

        if aspectChanged, let win = window {
            let targetSize = idealWindowContentSize(for: videoSize)
            var frame = CGRect(origin: .zero, size: targetSize)
            let oldCenter = CGPoint(x: win.frame.midX, y: win.frame.midY)
            frame.origin.x = oldCenter.x - frame.width * 0.5
            frame.origin.y = oldCenter.y - frame.height * 0.5
            if let screenFrame = (win.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, screenFrame.minX + 12), screenFrame.maxX - frame.width - 12)
                frame.origin.y = min(max(frame.origin.y, screenFrame.minY + 12), screenFrame.maxY - frame.height - 12)
            }
            win.setFrame(frame, display: true, animate: true)
        }
    }

    func setAlwaysOnTop(_ pinned: Bool) {
        window?.level = pinned ? .floating : .normal
        updatePinButtonAppearance(pinned)
    }

    func updateDimButtonAppearance(_ dimmed: Bool) {
        guard let btn = dimButton else { return }
        btn.image = NSImage(systemSymbolName: dimmed ? "moon.fill" : "sun.max", accessibilityDescription: "Dim Phone Screen")
        btn.contentTintColor = dimmed ? MirrorThemeColors.lime : MirrorThemeColors.soft
        btn.toolTip = dimmed ? "Phone screen dimmed (tap to restore brightness)" : "Dim phone screen while mirroring"
    }

    func closeWindow() {
        hasReceivedFirstFrame = false
        canvasView?.reset(message: "")
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let activeId = PhoneMirrorManager.shared.activeDeviceId {
            PhoneMirrorManager.shared.stopMirroring(deviceId: activeId, notifyDevice: true)
        }
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let pad = Self.bezelInset * 2.0
        let aspect = max(0.35, min(2.4, currentVideoSize.width / max(1, currentVideoSize.height)))
        let videoH = max(360, frameSize.height - pad)
        let videoW = max(220, round(videoH * aspect))
        return NSSize(width: videoW + pad, height: videoH + pad)
    }

    private func isOrientationChanged(from oldSize: CGSize, to newSize: CGSize) -> Bool {
        let wasLandscape = oldSize.width > oldSize.height
        let isLandscape = newSize.width > newSize.height
        return wasLandscape != isLandscape
    }

    private func idealWindowContentSize(for videoSize: CGSize) -> CGSize {
        let pad = Self.bezelInset * 2.0
        let aspect = max(0.35, min(2.4, videoSize.width / max(1, videoSize.height)))
        if aspect > 1.0 {
            let videoW: CGFloat = 680
            let videoH = min(560, round(videoW / aspect))
            return CGSize(width: videoW + pad, height: videoH + pad)
        } else {
            let videoH: CGFloat = 760
            let videoW = max(290, round(videoH * aspect))
            return CGSize(width: videoW + pad, height: videoH + pad)
        }
    }

    private func refreshHoverBarVisibility(animated: Bool) {
        guard let pill = hoverPillView else { return }
        let shouldShow = !hasReceivedFirstFrame || isMouseInHoverZone
        let targetAlpha: CGFloat = shouldShow ? 1.0 : 0.0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                pill.animator().alphaValue = targetAlpha
            }
        } else {
            pill.alphaValue = targetAlpha
        }
    }

    private func ensureWindow(deviceName: String, videoSize: CGSize) -> NSWindow {
        if let existing = window {
            return existing
        }

        let contentSize = idealWindowContentSize(for: videoSize)
        let win = PhoneMirrorWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Bridge · \(deviceName)"
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 240, height: 380)
        win.delegate = self

        let bezel = PhoneBezelView(frame: NSRect(origin: .zero, size: contentSize))
        bezel.autoresizingMask = [.width, .height]
        bezel.onHoverStateChanged = { [weak self] hoveringTop in
            guard let self = self else { return }
            if self.isMouseInHoverZone != hoveringTop {
                self.isMouseInHoverZone = hoveringTop
                self.refreshHoverBarVisibility(animated: true)
            }
        }

        let canvas = PhoneMirrorCanvasView(frame: .zero)
        canvas.translatesAutoresizingMaskIntoConstraints = false

        // Hover-reveal floating control pill (hidden during normal phone interaction)
        let pill = HoverPillView(frame: .zero)
        pill.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = makePillIconButton(symbol: "xmark", tooltip: "Stop Mirroring", action: #selector(handleStopButton), tint: MirrorThemeColors.coral)

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = MirrorThemeColors.amber.cgColor

        let title = NSTextField(labelWithString: deviceName)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont(name: "PlusJakartaSans-SemiBold", size: 11.5) ?? NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        title.textColor = MirrorThemeColors.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let homeBtn = makePillIconButton(symbol: "house.fill", tooltip: "Home (⌘1)", action: #selector(handleNavHome))
        let recentsBtn = makePillIconButton(symbol: "square.on.square", tooltip: "App Switcher (⌘2)", action: #selector(handleNavRecents))
        let backBtn = makePillIconButton(symbol: "chevron.backward", tooltip: "Back (⌘3 / Esc)", action: #selector(handleNavBack))
        let dimBtn = makePillIconButton(symbol: "moon.fill", tooltip: "Dim Phone Screen", action: #selector(handleDimButton))
        let pinBtn = makePillIconButton(symbol: "pin", tooltip: "Keep Always on Top", action: #selector(handlePinButton))

        pill.addSubview(closeBtn)
        pill.addSubview(dot)
        pill.addSubview(title)
        pill.addSubview(homeBtn)
        pill.addSubview(recentsBtn)
        pill.addSubview(backBtn)
        pill.addSubview(dimBtn)
        pill.addSubview(pinBtn)

        bezel.addSubview(canvas)
        bezel.addSubview(pill)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: bezel.topAnchor, constant: Self.bezelInset),
            canvas.bottomAnchor.constraint(equalTo: bezel.bottomAnchor, constant: -Self.bezelInset),
            canvas.leadingAnchor.constraint(equalTo: bezel.leadingAnchor, constant: Self.bezelInset),
            canvas.trailingAnchor.constraint(equalTo: bezel.trailingAnchor, constant: -Self.bezelInset),

            pill.topAnchor.constraint(equalTo: bezel.topAnchor, constant: 16),
            pill.leadingAnchor.constraint(equalTo: bezel.leadingAnchor, constant: 14),
            pill.trailingAnchor.constraint(equalTo: bezel.trailingAnchor, constant: -14),
            pill.heightAnchor.constraint(equalToConstant: 34),

            closeBtn.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
            closeBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            dot.leadingAnchor.constraint(equalTo: closeBtn.trailingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            title.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            title.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: homeBtn.leadingAnchor, constant: -4),

            pinBtn.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
            pinBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            dimBtn.trailingAnchor.constraint(equalTo: pinBtn.leadingAnchor, constant: -2),
            dimBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            backBtn.trailingAnchor.constraint(equalTo: dimBtn.leadingAnchor, constant: -2),
            backBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            recentsBtn.trailingAnchor.constraint(equalTo: backBtn.leadingAnchor, constant: -2),
            recentsBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor),

            homeBtn.trailingAnchor.constraint(equalTo: recentsBtn.leadingAnchor, constant: -2),
            homeBtn.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])

        win.contentView = bezel
        win.center()
        win.canvasViewRef = canvas

        self.window = win
        self.bezelView = bezel
        self.hoverPillView = pill
        self.statusDotView = dot
        self.titleLabel = title
        self.dimButton = dimBtn
        self.pinButton = pinBtn
        self.canvasView = canvas
        return win
    }

    private func updatePinButtonAppearance(_ pinned: Bool) {
        guard let btn = pinButton else { return }
        btn.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")
        btn.contentTintColor = pinned ? MirrorThemeColors.lime : MirrorThemeColors.soft
    }

    private func makePillIconButton(
        symbol: String,
        tooltip: String,
        action: Selector,
        tint: NSColor = MirrorThemeColors.soft
    ) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = tint
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 12
        btn.layer?.backgroundColor = MirrorThemeColors.pillBtn.cgColor
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 24),
            btn.heightAnchor.constraint(equalToConstant: 24)
        ])
        return btn
    }

    // MARK: - Actions

    @objc private func handlePinButton() {
        PhoneMirrorManager.shared.isAlwaysOnTop.toggle()
    }

    @objc private func handleDimButton() {
        PhoneMirrorManager.shared.togglePhoneScreenDimmed()
    }

    @objc private func handleStopButton() {
        PhoneMirrorManager.shared.stopMirroring(notifyDevice: true)
    }

    @objc private func handleNavBack() {
        PhoneMirrorManager.shared.sendGlobalAction("back")
    }

    @objc private func handleNavHome() {
        PhoneMirrorManager.shared.sendGlobalAction("home")
    }

    @objc private func handleNavRecents() {
        PhoneMirrorManager.shared.sendGlobalAction("recents")
    }
}
