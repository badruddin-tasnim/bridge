import Foundation
import AppKit
import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins
import UserNotifications

class BridgeModel: ObservableObject {
    @Published var rawCode: String = ""
    @Published var formattedCode: String = ""
    @Published var localIp: String = "127.0.0.1"
    @Published var port: Int = 8765
    @Published var deviceName: String = "Mac"
    @Published var isConnected: Bool = false
    @Published var connectedDevice: String? = nil
    @Published var pairedDevice: String? = nil
    @Published var lastSyncedText: String? = nil
    @Published var lastSyncedOutgoing: Bool = false
    @Published var qrCodeImage: NSImage? = nil
    @Published var copiedNotice: Bool = false
    @Published var connectedDevicesList: [ConnectedDeviceInfo] = []
    @Published var selectedTargetDeviceId: UUID? = nil
    @Published var isDropTargeted: Bool = false
    @Published var deviceToUnpair: ConnectedDeviceInfo? = nil
    enum BridgeTab: String, CaseIterable {
        case devices = "Devices"
        case notifications = "Notifications"
        case files = "Transfer"
        case settings = "Settings"
    }
    @Published var selectedTab: BridgeTab = .devices {
        didSet {
            if selectedTab != .devices && showPairingSection {
                showPairingSection = false
            }
            onSizeChangeRequested?()
        }
    }
    var notificationsManager: BridgeNotificationManager {
        return BridgeNotificationManager.shared
    }
    var fileTransferManager: BridgeFileTransferManager {
        return BridgeFileTransferManager.shared
    }

    @Published var showPairingSection: Bool = false {
        didSet {
            onSizeChangeRequested?()
        }
    }
    @Published var showUnpairConfirmation: Bool = false {
        didSet {
            onSizeChangeRequested?()
        }
    }
    @Published var availableUpdateVersion: String? = nil {
        didSet {
            onSizeChangeRequested?()
        }
    }
    @Published var availableUpdateUrl: String? = nil

    var onSizeChangeRequested: (() -> Void)?
    
    let server = BridgeServer()
    private var updateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Update Checker Constants
    private static let githubLatestReleaseUrl = "https://api.github.com/repos/badruddin-tasnim/bridge/releases/latest"
    private static let fallbackReleasesUrl = "https://github.com/badruddin-tasnim/bridge/releases/latest"
    private static let oneDaySeconds: TimeInterval = 24 * 60 * 60
    private static let minCheckIntervalSeconds: TimeInterval = 60 * 60
    private static let keyLatestVersion = "bridge_update_latest_version"
    private static let keyDownloadUrl = "bridge_update_download_url"
    private static let keyDismissedVersion = "bridge_update_dismissed_version"
    private static let keyDismissedAt = "bridge_update_dismissed_at"
    private static let keyLastNotifiedVersion = "bridge_update_last_notified_version"
    private static let keyLastNotifiedAt = "bridge_update_last_notified_at"
    private static let keyLastCheckAt = "bridge_update_last_check_at"
    private static let keyPairedDevice = "bridge_paired_device_name"
    
    init() {
        self.rawCode = server.pairingCode
        if rawCode.count == 6 {
            self.formattedCode = "\(rawCode.prefix(3)) \(rawCode.suffix(3))"
        } else {
            self.formattedCode = rawCode
        }
        
        self.deviceName = Host.current().localizedName ?? "Mac"
        self.port = Int(server.port.rawValue)
        self.localIp = getPrimaryIPv4Address() ?? "127.0.0.1"
        self.pairedDevice = UserDefaults.standard.string(forKey: BridgeModel.keyPairedDevice)
        
        updateQrCode()
        setupServerCallbacks()
        server.start()

        BridgeNotificationManager.shared.$activeNotifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onSizeChangeRequested?()
            }
            .store(in: &cancellables)

        BridgeFileTransferManager.shared.$transfers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onSizeChangeRequested?()
            }
            .store(in: &cancellables)

        startUpdateChecking()
    }
    
    private func setupServerCallbacks() {
        server.onStatusChanged = { [weak self] connected, device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnected = connected
                self.connectedDevice = device
                if connected {
                    if let dev = device, !dev.isEmpty {
                        self.pairedDevice = dev
                        UserDefaults.standard.set(dev, forKey: BridgeModel.keyPairedDevice)
                    }
                    self.showPairingSection = false
                }
                self.onSizeChangeRequested?()
            }
        }

        server.onConnectedDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.connectedDevicesList = devices
                if let first = devices.first {
                    self.connectedDevice = first.name
                    self.pairedDevice = first.name
                    UserDefaults.standard.set(first.name, forKey: BridgeModel.keyPairedDevice)
                    if self.selectedTargetDeviceId == nil || !devices.contains(where: { $0.id == self.selectedTargetDeviceId }) {
                        self.selectedTargetDeviceId = first.id
                    }
                } else {
                    self.selectedTargetDeviceId = nil
                }
                self.onSizeChangeRequested?()
            }
        }
        
        server.onClipboardSynced = { [weak self] text, outgoing in
            guard let self = self else { return }
            self.lastSyncedText = text
            self.lastSyncedOutgoing = outgoing
        }
        
        server.onIpChanged = { [weak self] newIp in
            guard let self = self else { return }
            if self.localIp != newIp {
                self.localIp = newIp
                self.updateQrCode()
            }
        }
    }
    
    func updateQrCode() {
        let jsonDict: [String: Any] = [
            "bridge": "pair",
            "ip": localIp,
            "port": port,
            "code": rawCode,
            "name": deviceName
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        
        self.qrCodeImage = generateQrImage(from: jsonString)
    }
    
    private func generateQrImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        
        guard let outputImage = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 7, y: 7)
        let scaledImage = outputImage.transformed(by: scale)
        
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaledImage.extent.width, height: scaledImage.extent.height))
    }
    
    func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawCode, forType: .string)
        copiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copiedNotice = false
        }
    }
    
    func unpair(deviceId: UUID? = nil) {
        if let id = deviceId {
            server.disconnectDevice(id: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.connectedDevicesList.removeAll { $0.id == id }
                if self.connectedDevicesList.isEmpty {
                    self.pairedDevice = nil
                    UserDefaults.standard.removeObject(forKey: BridgeModel.keyPairedDevice)
                    self.isConnected = false
                    self.connectedDevice = nil
                    self.selectedTargetDeviceId = nil
                } else if let first = self.connectedDevicesList.first {
                    self.pairedDevice = first.name
                    self.connectedDevice = first.name
                    UserDefaults.standard.set(first.name, forKey: BridgeModel.keyPairedDevice)
                    if self.selectedTargetDeviceId == id || self.selectedTargetDeviceId == nil {
                        self.selectedTargetDeviceId = first.id
                    }
                }
                self.deviceToUnpair = nil
                self.onSizeChangeRequested?()
            }
        } else {
            pairedDevice = nil
            connectedDevicesList.removeAll()
            selectedTargetDeviceId = nil
            deviceToUnpair = nil
            UserDefaults.standard.removeObject(forKey: BridgeModel.keyPairedDevice)
            server.unpairAllDevices()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.rawCode = self.server.pairingCode
                if self.rawCode.count == 6 {
                    self.formattedCode = "\(self.rawCode.prefix(3)) \(self.rawCode.suffix(3))"
                } else {
                    self.formattedCode = self.rawCode
                }
                self.updateQrCode()
                self.isConnected = false
                self.connectedDevice = nil
                self.showPairingSection = false
                self.onSizeChangeRequested?()
            }
        }
    }

    var targetDeviceDisplayName: String {
        if let selId = selectedTargetDeviceId,
           let dev = connectedDevicesList.first(where: { $0.id == selId }) {
            return dev.name
        }
        if let first = connectedDevicesList.first {
            return first.name
        }
        return pairedDevice ?? "Android"
    }

    func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let targetDev = connectedDevicesList.first(where: { $0.id == selectedTargetDeviceId })
            ?? connectedDevicesList.first
            ?? ConnectedDeviceInfo(id: UUID(), name: connectedDevice ?? pairedDevice ?? "Android", ip: nil, isConnected: isConnected)
        BridgeFileTransferManager.shared.sendFiles(urls: urls, to: targetDev)
    }

    func selectFilesToSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = "Select Files to Send to Android"
        panel.prompt = "Send"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            sendFiles(panel.urls)
        }
    }

    var statusText: String {
        if isConnected {
            return "CONNECTED"
        } else if pairedDevice != nil {
            return "DISCONNECTED"
        } else {
            return "WAITING"
        }
    }

    func openReleaseNotes() {
        if let urlStr = availableUpdateUrl, let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        } else if let fallback = URL(string: BridgeModel.fallbackReleasesUrl) {
            NSWorkspace.shared.open(fallback)
        }
    }

    // MARK: - GitHub Release Update Checker (24-Hour Cooldown)

    private func startUpdateChecking() {
        evaluateCachedUpdateState()
        checkForUpdates(forceNetwork: false)

        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(forceNetwork: false)
        }
    }

    func checkForUpdates(forceNetwork: Bool = false) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let lastCheck = defaults.double(forKey: Self.keyLastCheckAt)

        if !forceNetwork && (now - lastCheck < Self.minCheckIntervalSeconds) {
            evaluateCachedUpdateState()
            return
        }

        guard let url = URL(string: Self.githubLatestReleaseUrl) else { return }
        var request = URLRequest(url: url, timeoutInterval: 8.0)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bridge-macOS-App", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let httpResp = response as? HTTPURLResponse,
               httpResp.statusCode == 200,
               let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawTag = json["tag_name"] as? String {

                let cleanVersion = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)

                if !cleanVersion.isEmpty {
                    var targetUrl = (json["html_url"] as? String) ?? Self.fallbackReleasesUrl
                    if let assets = json["assets"] as? [[String: Any]] {
                        for asset in assets {
                            if let name = asset["name"] as? String,
                               let downloadUrl = asset["browser_download_url"] as? String,
                               name.lowercased().contains("macos") && name.lowercased().hasSuffix(".zip") {
                                targetUrl = downloadUrl
                                break
                            }
                        }
                    }

                    if !targetUrl.hasPrefix("https://github.com/badruddin-tasnim/bridge/") &&
                       !targetUrl.hasPrefix("https://objects.githubusercontent.com/") {
                        targetUrl = Self.fallbackReleasesUrl
                    }

                    defaults.set(cleanVersion, forKey: Self.keyLatestVersion)
                    defaults.set(targetUrl, forKey: Self.keyDownloadUrl)
                    defaults.set(Date().timeIntervalSince1970, forKey: Self.keyLastCheckAt)
                }
            }
            DispatchQueue.main.async {
                self.evaluateCachedUpdateState()
            }
        }.resume()
    }

    private func evaluateCachedUpdateState() {
        let defaults = UserDefaults.standard
        guard let latestVersion = defaults.string(forKey: Self.keyLatestVersion), !latestVersion.isEmpty else {
            if availableUpdateVersion != nil { availableUpdateVersion = nil }
            return
        }

        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        guard Self.isNewerVersion(remote: latestVersion, current: currentVersion) else {
            if availableUpdateVersion != nil { availableUpdateVersion = nil }
            return
        }

        // Check if user dismissed this version within the last 24 hours (1 day)
        let now = Date().timeIntervalSince1970
        let dismissedVer = defaults.string(forKey: Self.keyDismissedVersion)
        let dismissedAt = defaults.double(forKey: Self.keyDismissedAt)
        if dismissedVer == latestVersion && (now - dismissedAt) < Self.oneDaySeconds {
            if availableUpdateVersion != nil { availableUpdateVersion = nil }
            return
        }

        let downloadUrl = defaults.string(forKey: Self.keyDownloadUrl) ?? Self.fallbackReleasesUrl
        availableUpdateUrl = downloadUrl
        if availableUpdateVersion != latestVersion {
            availableUpdateVersion = latestVersion
        }

        // Post native macOS notification at most once per day (24 hours)
        let lastNotifiedVer = defaults.string(forKey: Self.keyLastNotifiedVersion)
        let lastNotifiedAt = defaults.double(forKey: Self.keyLastNotifiedAt)
        if lastNotifiedVer != latestVersion || (now - lastNotifiedAt) >= Self.oneDaySeconds {
            postSystemUpdateNotification(version: latestVersion)
            defaults.set(latestVersion, forKey: Self.keyLastNotifiedVersion)
            defaults.set(now, forKey: Self.keyLastNotifiedAt)
        }
    }

    func dismissUpdateForToday() {
        let defaults = UserDefaults.standard
        guard let latestVersion = defaults.string(forKey: Self.keyLatestVersion) else {
            availableUpdateVersion = nil
            return
        }
        defaults.set(latestVersion, forKey: Self.keyDismissedVersion)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.keyDismissedAt)

        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["bridge_update_notification"])
        availableUpdateVersion = nil
    }

    func openUpdateDownload() {
        let urlStr = availableUpdateUrl ?? Self.fallbackReleasesUrl
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    private func postSystemUpdateNotification(version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Bridge v\(version) is available"
            content.body = "Open Bridge in your menu bar to download the latest update from GitHub."
            content.sound = .default

            let req = UNNotificationRequest(
                identifier: "bridge_update_notification",
                content: content,
                trigger: nil
            )
            center.add(req, withCompletionHandler: nil)
        }
    }

    static func isNewerVersion(remote: String, current: String) -> Bool {
        let rParts = parseVersionParts(remote)
        let cParts = parseVersionParts(current)
        let count = max(rParts.count, cParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let c = i < cParts.count ? cParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private static func parseVersionParts(_ version: String) -> [Int] {
        let cleaned = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[vV]", with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet(charactersIn: "-+")).first ?? ""
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }
}
