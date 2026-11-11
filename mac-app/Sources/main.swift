import AppKit
import SwiftUI
import CoreText
import UniformTypeIdentifiers

// MARK: - Font Registration

func registerCustomFonts() {
    guard let resourcePath = Bundle.main.resourcePath else { return }
    let fontsPath = (resourcePath as NSString).appendingPathComponent("Fonts")
    guard let fontFiles = try? FileManager.default.contentsOfDirectory(atPath: fontsPath) else { return }
    
    for file in fontFiles where file.hasSuffix(".ttf") || file.hasSuffix(".otf") {
        let fontUrl = URL(fileURLWithPath: (fontsPath as NSString).appendingPathComponent(file))
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(fontUrl as CFURL, .process, &error)
    }
}

// MARK: - Status Item Drag & Drop Overlay View

final class StatusItemDropOverlayView: NSView {
    var onDragEntered: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // Pass normal mouse clicks through to NSStatusBarButton underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.onDragEntered?()
            }
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        DispatchQueue.main.async { [weak self] in
            self?.onFilesDropped?(urls)
        }
        return true
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = BridgeModel()
    private var lastPopoverCloseTime: TimeInterval = 0
    private var isAnimatingClose = false
    private var isFinishingAnimatedClose = false
    private var closeGeneration = 0
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerCustomFonts()
        if let iconPath = Bundle.main.path(forResource: "Bridge", ofType: "icns"),
           let appIcon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = appIcon
        }
        NSApp.servicesProvider = self
        setupStatusItem()
        setupPopover()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        button.image = createBridgeTemplateIcon()
        button.imagePosition = .imageOnly
        button.action = #selector(togglePopover)
        button.target = self
        button.sendAction(on: [.leftMouseDown])

        let dropOverlay = StatusItemDropOverlayView(frame: button.bounds)
        dropOverlay.autoresizingMask = [.width, .height]
        dropOverlay.onDragEntered = { [weak self] in
            guard let self = self else { return }
            if self.model.selectedTab != .files {
                self.model.selectedTab = .files
            }
            self.showPopover()
        }
        dropOverlay.onFilesDropped = { [weak self] urls in
            guard let self = self else { return }
            self.handleIncomingSharedFiles(urls)
        }
        button.addSubview(dropOverlay)
    }
    
    private func setupPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.delegate = self
        let hostingController = NSHostingController(rootView: BridgeMenuView(model: model))
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }
        pop.contentViewController = hostingController
        self.popover = pop
        
        model.onSizeChangeRequested = { [weak self] in
            DispatchQueue.main.async {
                self?.applyPopoverSize()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                    self?.applyPopoverSize()
                }
            }
        }
    }
    
    private func applyPopoverSize() {
        guard let pop = popover, let controller = pop.contentViewController else { return }

        controller.view.invalidateIntrinsicContentSize()
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        
        let targetHeight: CGFloat
        if fitting.height > 150 {
            targetHeight = ceil(fitting.height)
        } else {
            let isPaired = model.isConnected || model.pairedDevice != nil
            let notifCount = BridgeNotificationManager.shared.activeNotifications.count
            if !isPaired {
                targetHeight = 494
            } else if model.selectedTab == .devices && model.showPairingSection {
                targetHeight = 658
            } else if model.selectedTab == .devices {
                let devCount = max(1, model.connectedDevicesList.count)
                targetHeight = 240 + CGFloat(devCount) * 75.0
            } else if model.selectedTab == .files {
                let txCount = BridgeFileTransferManager.shared.transfers.count
                targetHeight = txCount == 0 ? 310 : min(340 + CGFloat(txCount) * 70.0, 580.0)
            } else if model.selectedTab == .settings {
                targetHeight = 460
            } else {
                targetHeight = notifCount == 0 ? 444 : min(444 + CGFloat(notifCount) * 85.0, 620.0)
            }
        }
        
        let newSize = NSSize(width: 380, height: targetHeight)
        if pop.contentSize != newSize {
            pop.contentSize = newSize
        }
        if let window = controller.view.window {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = NSColor(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0, alpha: 1.0)
        }
    }
    
    @objc private func togglePopover() {
        guard let pop = popover else { return }
        let now = CACurrentMediaTime()
        if pop.isShown {
            closePopoverAnimated()
            lastPopoverCloseTime = now
            return
        }
        // If the popover was closed by a click outside or on the status item within 300ms, ignore reopening
        if now - lastPopoverCloseTime < 0.3 {
            return
        }
        showPopover()
    }

    private func showPopover(forceBringToFront: Bool = false) {
        guard let button = statusItem?.button, let pop = popover else { return }
        BridgeNotificationManager.shared.checkNotificationAuth()
        model.checkForUpdates(forceNetwork: false)
        applyPopoverSize()

        NSApp.activate(ignoringOtherApps: true)

        if forceBringToFront {
            // Prevent immediate auto-dismissal while Finder is closing its context menu
            pop.behavior = .applicationDefined
        }

        // Reopened mid-close (e.g. Finder share or drag-and-drop): the popover is
        // still shown, so cancel the close and animate back in. Setting alphaValue
        // directly would not stop the in-flight animator() fade to 0.
        var didOpen = false
        var resumingFromClose = false
        if isAnimatingClose {
            isAnimatingClose = false
            closeGeneration += 1  // invalidates the pending close completion
            resumingFromClose = true
        }

        if !pop.isShown {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            didOpen = true
        }

        if let window = pop.contentViewController?.view.window {
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.backgroundColor = NSColor(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0, alpha: 1.0)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        applyPopoverSize()

        if didOpen || resumingFromClose {
            animatePopoverIn(resumingFromClose: resumingFromClose)
        }

        if forceBringToFront {
            // Restore standard transient click-outside dismissal once the Finder context menu action settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self = self, let pop = self.popover else { return }
                pop.behavior = .transient
                self.applyPopoverSize()
            }
        }
    }

    // MARK: - Open / Close Animation
    // NSPopover's built-in animation is off (it fights the resize right after
    // showing), so we fade the popover window and slide its content instead.

    private static let openDuration: TimeInterval = 0.2
    private static let closeDuration: TimeInterval = 0.14
    private static let slideDistance: CGFloat = 8

    /// `resumingFromClose`: the popover is mid fade-out, so fade back up from its
    /// current alpha instead of starting at 0 (which would flicker).
    private func animatePopoverIn(resumingFromClose: Bool = false) {
        guard let view = popover?.contentViewController?.view, let window = view.window else { return }
        isAnimatingClose = false
        view.layer?.removeAnimation(forKey: "bridgeSlide")
        if !resumingFromClose {
            window.alphaValue = 0
        }

        if !resumingFromClose && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.wantsLayer = true
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = Self.slideDistance  // start slightly up, toward the menu bar
            slide.toValue = 0
            slide.duration = Self.openDuration
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            view.layer?.add(slide, forKey: "bridgeSlide")
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.openDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func closePopoverAnimated() {
        guard let pop = popover, pop.isShown, !isAnimatingClose else { return }
        guard let view = pop.contentViewController?.view, let window = view.window else {
            pop.close()
            return
        }
        isAnimatingClose = true
        closeGeneration += 1
        let generation = closeGeneration
        // The reopen debounce in togglePopover() counts from when the close starts.
        lastPopoverCloseTime = CACurrentMediaTime()

        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.wantsLayer = true
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = 0
            slide.toValue = Self.slideDistance
            slide.duration = Self.closeDuration
            slide.timingFunction = CAMediaTimingFunction(name: .easeIn)
            slide.fillMode = .forwards
            slide.isRemovedOnCompletion = false
            view.layer?.add(slide, forKey: "bridgeSlide")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.closeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self, self.isAnimatingClose, generation == self.closeGeneration else { return }
            self.isAnimatingClose = false
            self.isFinishingAnimatedClose = true  // keep the delegate from resetting the debounce
            pop.close()  // close() skips popoverShouldClose, so this doesn't loop
            view.layer?.removeAnimation(forKey: "bridgeSlide")
            window.alphaValue = 1
        })
    }

    // MARK: - NSPopoverDelegate

    // Clicks outside / Esc land here for a transient popover: animate out first.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        closePopoverAnimated()
        return false
    }

    func popoverWillClose(_ notification: Notification) {
        if !isFinishingAnimatedClose {
            lastPopoverCloseTime = CACurrentMediaTime()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if !isFinishingAnimatedClose {
            lastPopoverCloseTime = CACurrentMediaTime()
        }
        isFinishingAnimatedClose = false
        model.hideAllIpAddresses()
    }

    // MARK: - Finder Right-Click / Share / Services / Open With Integration

    private func handleIncomingSharedFiles(_ urls: [URL]) {
        let validFiles = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !validFiles.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.model.selectedTab = .files
            self.showPopover(forceBringToFront: true)
            self.model.sendFiles(validFiles)

            // Re-trigger slightly later in case the menu bar layout needed an extra cycle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.showPopover(forceBringToFront: true)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(forceBringToFront: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var fileUrls: [URL] = []
        for url in urls {
            if url.isFileURL {
                fileUrls.append(url)
            } else if url.scheme?.lowercased() == "bridge" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let queryItems = components.queryItems {
                    for item in queryItems where item.name == "path" {
                        if let path = item.value, !path.isEmpty {
                            fileUrls.append(URL(fileURLWithPath: path))
                        }
                    }
                }
            }
        }
        handleIncomingSharedFiles(fileUrls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        handleIncomingSharedFiles(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    @objc func shareWithBridge(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            handleIncomingSharedFiles(urls)
        }
    }
    
    private func createBridgeTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        if let path2x = Bundle.main.path(forResource: "MenuBarIcon@2x", ofType: "png"),
           let img = NSImage(contentsOfFile: path2x) {
            img.size = size
            img.isTemplate = true
            return img
        }
        if let path = Bundle.main.path(forResource: "MenuBarIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = size
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(size: size)
        fallback.isTemplate = true
        return fallback
    }
}

// MARK: - Application Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar accessory (no dock icon clutter)
app.run()
