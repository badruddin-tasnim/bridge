import AppKit
import SwiftUI
import CoreText

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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = BridgeModel()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerCustomFonts()
        if let iconPath = Bundle.main.path(forResource: "Bridge", ofType: "icns"),
           let appIcon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = appIcon
        }
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
    }
    
    private func setupPopover() {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: .darkAqua)
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
            } else if model.selectedTab == .notifications && model.showPairingSection {
                targetHeight = 658
            } else if model.selectedTab == .settings {
                targetHeight = 665
            } else {
                targetHeight = notifCount == 0 ? 444 : min(444 + CGFloat(notifCount) * 85.0, 620.0)
            }
        }
        
        let newSize = NSSize(width: 380, height: targetHeight)
        if pop.contentSize != newSize {
            pop.contentSize = newSize
        }
        if let window = controller.view.window {
            window.backgroundColor = NSColor(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0, alpha: 1.0)
        }
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            BridgeNotificationManager.shared.checkNotificationAuth()
            model.checkForUpdates(forceNetwork: false)
            applyPopoverSize()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = pop.contentViewController?.view.window {
                window.backgroundColor = NSColor(red: 0x12 / 255.0, green: 0x14 / 255.0, blue: 0x18 / 255.0, alpha: 1.0)
                window.makeKey()
            }
            DispatchQueue.main.async { [weak self] in
                self?.applyPopoverSize()
            }
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
