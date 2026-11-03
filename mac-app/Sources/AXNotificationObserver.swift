import Foundation
import AppKit
import ApplicationServices

func logDebugAX(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        let logUrl = URL(fileURLWithPath: "/tmp/bridge_debug.log")
        if let handle = try? FileHandle(forWritingTo: logUrl) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: logUrl)
        }
    }
}

public class AXNotificationObserver: ObservableObject {

    public static let shared = AXNotificationObserver()

    @Published public var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

    public var onNotificationCaptured: ((BridgeNotification) -> Void)?

    private var observer: AXObserver?
    private var observerSource: CFRunLoopSource?
    private var isObserving = false
    private var recentAlertHashes = Set<String>()
    private var activeCardElements = [String: AXUIElement]() // id -> AXUIElement
    private var pollSourceTimer: DispatchSourceTimer?
    private var tickCount = 0
    private var iconCache = [String: String]()

    private init() {
        self.isAccessibilityTrusted = AXIsProcessTrusted()
    }

    public func promptAccessibilityPermissions() {
        NSApp.activate(ignoringOtherApps: true)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    public func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for urlStr in urls {
            if let url = URL(string: urlStr) {
                if NSWorkspace.shared.open(url) { return }
            }
        }
    }

    public func checkTrustNow() {
        let trusted = AXIsProcessTrusted()
        if self.isAccessibilityTrusted != trusted {
            self.isAccessibilityTrusted = trusted
            logDebugAX("checkTrustNow: Trust changed to \(trusted)")
        }
        if trusted {
            checkObserverHealth()
            scanActiveNotificationWindows()
        }
    }

    public func start() {
        if isObserving { return }
        isObserving = true

        self.isAccessibilityTrusted = AXIsProcessTrusted()
        logDebugAX("start() called. isAccessibilityTrusted=\(isAccessibilityTrusted)")

        if isAccessibilityTrusted {
            startObservingNotificationCenter()
        }

        pollSourceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            self?.periodicCheck()
        }
        timer.resume()
        self.pollSourceTimer = timer
    }

    public func stop() {
        pollSourceTimer?.cancel()
        pollSourceTimer = nil

        if observer != nil, let src = observerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            self.observer = nil
            self.observerSource = nil
        }
        isObserving = false
    }

    private func periodicCheck() {
        let trusted = AXIsProcessTrusted()
        tickCount += 1
        if tickCount % 5 == 0 {
            logDebugAX("periodicCheck heartbeat: trusted=\(trusted)")
        }

        if self.isAccessibilityTrusted != trusted {
            self.isAccessibilityTrusted = trusted
            logDebugAX("Accessibility trust changed to: \(trusted)")
            NSLog("[AXNotifObserver] Accessibility trust changed to: \(trusted)")
        }

        if trusted {
            checkObserverHealth()
            scanActiveNotificationWindows()
        }
    }

    private func checkObserverHealth() {
        guard AXIsProcessTrusted() else { return }
        if observer == nil {
            startObservingNotificationCenter()
        }
    }

    private func startObservingNotificationCenter() {
        let targetBundleIds = [
            "com.apple.notificationcenterui",
            "com.apple.UserNotificationCenter"
        ]

        var targetApp: NSRunningApplication?
        for bid in targetBundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                targetApp = app
                break
            }
        }

        guard let ncApp = targetApp else {
            logDebugAX("startObserving: No target app found for notification observing.")
            return
        }

        let pid = ncApp.processIdentifier
        var localObserver: AXObserver?

        let callback: AXObserverCallback = { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let instance = Unmanaged<AXNotificationObserver>.fromOpaque(refcon).takeUnretainedValue()
            instance.handleAXEvent(element: element, notification: notification as String)
        }

        let result = AXObserverCreate(pid, callback, &localObserver)
        guard result == .success, let obs = localObserver else {
            logDebugAX("Failed to create AXObserver for PID \(pid): \(result.rawValue)")
            return
        }

        self.observer = obs
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let noteNames: [CFString] = [
            kAXWindowCreatedNotification as CFString,
            kAXFocusedUIElementChangedNotification as CFString,
            kAXLayoutChangedNotification as CFString
        ]

        for note in noteNames {
            AXObserverAddNotification(obs, appElement, note, refcon)
        }

        let source = AXObserverGetRunLoopSource(obs)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.observerSource = source

        logDebugAX("Attached AXObserver to \(ncApp.bundleIdentifier ?? "") (PID: \(pid)).")
    }

    private func handleAXEvent(element: AXUIElement, notification: String) {
        logDebugAX("handleAXEvent received: \(notification)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scanActiveNotificationWindows()
        }
    }

    public func scanActiveNotificationWindows() {
        guard AXIsProcessTrusted() else { return }

        let targetBundleIds = [
            "com.apple.notificationcenterui",
            "com.apple.UserNotificationCenter"
        ]

        var targetApps: [NSRunningApplication] = []
        for bid in targetBundleIds {
            targetApps.append(contentsOf: NSRunningApplication.runningApplications(withBundleIdentifier: bid))
        }

        for app in targetApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            var elementsToInspect: [AXUIElement] = []

            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                elementsToInspect.append(contentsOf: windows)
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children {
                    elementsToInspect.append(child)
                }
            }

            for element in elementsToInspect {
                inspectWindowForAlert(element)
            }
        }
    }

    private func inspectWindowForAlert(_ window: AXUIElement) {
        var stringsFound: [String] = []
        extractTexts(from: window, into: &stringsFound, depth: 0)

        guard !stringsFound.isEmpty else { return }

        let ignoredWords: Set<String> = [
            "options", "reply", "close", "clear all", "clear", "more", "notification center",
            "actions", "snooze", "manage", "dismiss", "mute",
            "confirm show less", "show less", "show more", "confirm", "open", "view",
            "today", "yesterday", "widgets", "edit widgets", "mark as read"
        ]

        let cleanStrings = stringsFound
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { str in
                let lower = str.lowercased()
                if lower.isEmpty || ignoredWords.contains(lower) { return false }
                if lower.starts(with: "confirm show less") || lower.starts(with: "show less") || lower.starts(with: "show more") {
                    return false
                }
                return true
            }

        guard cleanStrings.count >= 2 else { return }

        let appName = cleanStrings[0]
        let lowerApp = appName.lowercased()

        // 1. Blacklist system widgets, macOS tools, and input helpers
        let blacklistedApps: Set<String> = [
            "screentime", "screen time", "screentimewidget", "screentimeextension",
            "calendar", "calendar widget", "clock", "weather", "weather widget",
            "script editor", "applescript", "automator", "shortcuts",
            "controlcenter", "control center", "control center widget",
            "system information", "about this mac", "apple",
            "notification center", "notificationcenter", "notificationcenterui",
            "bridge", "finder", "dock",
            "system settings", "system preferences",
            "battery", "wifi", "wi-fi", "bluetooth", "sound", "display",
            "today", "widgets", "corelocationagent",
            "autofill", "passwords", "passwords…", "contact…", "credit card…", "dictation", "emoji & symbols"
        ]

        if blacklistedApps.contains(lowerApp) || lowerApp.contains("widget") || lowerApp.contains("screentime") || lowerApp.contains("bridge") || lowerApp.contains("autofill") || lowerApp == "apple" {
            return
        }

        let title: String
        let body: String
        if cleanStrings.count == 2 {
            title = ""
            body = cleanStrings[1]
        } else {
            title = cleanStrings[1]
            body = cleanStrings[2...].joined(separator: "\n")
        }

        let lowerTitle = title.lowercased()
        let lowerBody = body.lowercased()

        if blacklistedApps.contains(lowerTitle) || lowerTitle.contains("about this mac") || lowerTitle.contains("screentime") || lowerTitle.contains("widget") || lowerBody.contains("about this mac") {
            return
        }

        // Filter out Calendar / Date timeline widgets (e.g. "TUESDAY, 03 NOVEMBER", "WEDNESDAY, 04 NOVEMBER")
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        if dayNames.contains(where: { lowerTitle.starts(with: $0) || lowerBody.starts(with: $0) }) {
            return
        }

        // 2. Filter out phone-app echoes and notifications already mirrored from Android
        let isMirroredFromPhone = BridgeNotificationManager.shared.activeNotifications.contains { phoneNotif in
            let pApp = phoneNotif.app?.lowercased() ?? ""
            let pTitle = phoneNotif.title?.lowercased() ?? ""
            let pText = phoneNotif.text?.lowercased() ?? ""

            let appMatches = !pApp.isEmpty && (lowerApp == pApp || lowerApp.contains(pApp) || pApp.contains(lowerApp))
            let titleMatches = !pTitle.isEmpty && (lowerTitle == pTitle || lowerBody == pTitle || lowerTitle.contains(pTitle) || pTitle.contains(lowerTitle))
            let textMatches = !pText.isEmpty && (lowerBody == pText || lowerTitle == pText || (pText.count > 4 && lowerBody.contains(pText)))

            return appMatches || (titleMatches && textMatches)
        }
        if isMirroredFromPhone {
            logDebugAX("Dropping phone echo banner: [\(appName)] \(title): \(body)")
            return
        }

        let signature = "\(appName)|\(title)|\(body)"
        if recentAlertHashes.contains(signature) { return }
        recentAlertHashes.insert(signature)

        if recentAlertHashes.count > 50 {
            recentAlertHashes.removeFirst()
        }

        let notifId = "mac_\(Int(Date().timeIntervalSince1970))_\(abs(signature.hashValue % 10000))"
        activeCardElements[notifId] = window

        // Retrieve scaled 96x96 PNG base64 icon
        let iconBase64 = getAppIconBase64(appName: appName)

        let notif = BridgeNotification(
            id: notifId,
            source: "mac",
            pkg: "com.apple",
            app: appName,
            title: title,
            text: body,
            icon: iconBase64,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
        )

        logDebugAX("Captured Mac Notification: [\(appName)] \(title): \(body) (iconLen=\(iconBase64?.count ?? 0))")
        NSLog("[AXNotifObserver] Captured Mac Notification: [\(appName)] \(title): \(body)")
        onNotificationCaptured?(notif)
    }

    private func extractTexts(from element: AXUIElement, into results: inout [String], depth: Int) {
        if depth > 16 { return }

        var roleRef: CFTypeRef?
        var roleStr = ""
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            roleStr = role
        }

        // Skip buttons, sliders, and non-content controls
        if roleStr == (kAXButtonRole as String) || roleStr == "AXSlider" || roleStr == "AXScrollBar" {
            return
        }

        // Static text elements contain the clean individual text fields
        if roleStr == (kAXStaticTextRole as String) {
            var valRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef) == .success,
               let val = valRef {
                if let str = val as? String, !str.isEmpty {
                    let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !results.contains(trimmed) {
                        results.append(trimmed)
                    }
                } else if let attrStr = val as? NSAttributedString, !attrStr.string.isEmpty {
                    let trimmed = attrStr.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !results.contains(trimmed) {
                        results.append(trimmed)
                    }
                }
            }
        } else {
            // Fallback for custom views that have single title without compound descriptions
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
               let titleVal = titleRef as? String {
                let trimmed = titleVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !results.contains(trimmed) && trimmed.count < 80 {
                    results.append(trimmed)
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                extractTexts(from: child, into: &results, depth: depth + 1)
            }
        }
    }

    private func getAppIconBase64(appName: String) -> String? {
        let key = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = iconCache[key] {
            return cached
        }

        var image: NSImage?

        // 1. Try running apps with exact or substring match
        let runningApps = NSWorkspace.shared.runningApplications
        if let app = runningApps.first(where: {
            guard let name = $0.localizedName?.lowercased(), !name.isEmpty else { return false }
            return key == name || key.contains(name) || name.contains(key)
        }) {
            image = app.icon
        }

        // 2. Try standard application paths
        if image == nil {
            let firstWord = key.split(separator: " ").first.map(String.init) ?? key
            let candidateNames = [appName, firstWord]
            for cName in candidateNames {
                let candidates = [
                    "/Applications/\(cName).app",
                    "/System/Applications/\(cName).app",
                    "/System/Applications/Utilities/\(cName).app",
                    "/Applications/Utilities/\(cName).app"
                ]
                for p in candidates {
                    if FileManager.default.fileExists(atPath: p) {
                        image = NSWorkspace.shared.icon(forFile: p)
                        break
                    }
                }
                if image != nil { break }
            }
        }

        // 3. Try finding app in /Applications with prefix
        if image == nil {
            let firstWord = key.split(separator: " ").first.map(String.init) ?? key
            if let apps = try? FileManager.default.contentsOfDirectory(atPath: "/Applications") {
                if let match = apps.first(where: {
                    let lower = $0.lowercased()
                    return (lower.hasPrefix(firstWord) || lower.contains(firstWord)) && lower.hasSuffix(".app")
                }) {
                    image = NSWorkspace.shared.icon(forFile: "/Applications/\(match)")
                }
            }
        }

        guard let iconImage = image else { return nil }

        // Scale to 96x96 to keep payload small (~10KB PNG)
        let targetSize = NSSize(width: 96, height: 96)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        iconImage.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        let b64 = pngData.base64EncodedString()
        iconCache[key] = b64
        return b64
    }

    public func dismissMacNotification(id: String) {
        guard let window = activeCardElements[id] else {
            dismissAnyActiveBanner()
            return
        }

        if performCloseAction(on: window) {
            activeCardElements.removeValue(forKey: id)
            logDebugAX("Successfully dismissed Mac banner \(id)")
            NSLog("[AXNotifObserver] Successfully dismissed Mac banner \(id)")
        } else {
            dismissAnyActiveBanner()
        }
    }

    private func performCloseAction(on element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let actions = actionsRef as? [String] {
            for action in actions {
                if action == "AXPress" || action == "Close" || action == "Clear" {
                    AXUIElementPerformAction(element, action as CFString)
                    return true
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if performCloseAction(on: child) {
                    return true
                }
            }
        }
        return false
    }

    private func dismissAnyActiveBanner() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui")
        guard let ncApp = apps.first else { return }

        let appElement = AXUIElementCreateApplication(ncApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }

        for window in windows {
            if performCloseAction(on: window) {
                return
            }
        }
    }
}
