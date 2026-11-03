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
        pop.contentViewController = NSHostingController(rootView: BridgeMenuView(model: model))
        self.popover = pop
        
        model.onSizeChangeRequested = { [weak self] in
            DispatchQueue.main.async {
                self?.updatePopoverSize()
            }
        }
    }
    
    private func updatePopoverSize() {
        guard let pop = popover, let controller = pop.contentViewController else { return }
        controller.view.layoutSubtreeIfNeeded()
        let fitting = controller.view.fittingSize
        
        let targetHeight: CGFloat
        if fitting.height > 200 {
            targetHeight = ceil(fitting.height)
        } else {
            let notifCount = BridgeNotificationManager.shared.activeNotifications.count
            if !model.isConnected {
                targetHeight = 510
            } else if model.showPairingSection {
                targetHeight = 680
            } else if model.selectedTab == .settings {
                targetHeight = 460
            } else {
                targetHeight = notifCount == 0 ? 430 : min(430 + CGFloat(notifCount) * 80.0, 600.0)
            }
        }
        
        let newSize = NSSize(width: 380, height: targetHeight)
        if pop.contentSize != newSize {
            pop.contentSize = newSize
            if pop.isShown, let button = statusItem?.button {
                pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            BridgeNotificationManager.shared.checkNotificationAuth()
            model.checkForUpdates(forceNetwork: false)
            updatePopoverSize()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = pop.contentViewController?.view.window {
                window.makeKey()
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
