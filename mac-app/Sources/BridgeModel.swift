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
    @Published var revealedDeviceIpIds: Set<UUID> = []
    @Published var isLocalIpRevealed: Bool = false
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
            if selectedTab == .settings {
                refreshLaunchAtLoginStatus()
            }
            onSizeChangeRequested?()
        }
    }
    @Published var isLaunchAtLoginEnabled: Bool = false
    @Published var launchAtLoginRequiresApproval: Bool = false
    @Published var launchAtLoginError: String? = nil
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
    @Published var dndHintDeviceIds: Set<UUID> = []
    @Published var pendingRingerDeviceIds: Set<UUID> = []
    @Published var pendingDndDeviceIds: Set<UUID> = []
    @Published var pendingRingDeviceIds: Set<UUID> = []
    @Published var controlErrorHints: [UUID: String] = [:]
    @Published var isLowBatteryAlertEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "bridge_low_battery_alert_enabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "bridge_low_battery_alert_enabled")
    }() {
        didSet {
            UserDefaults.standard.set(isLowBatteryAlertEnabled, forKey: Self.keyLowBatteryAlertEnabled)
        }
    }
    @Published var isAutoPauseMacMediaEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "bridge_auto_pause_mac_media_enabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "bridge_auto_pause_mac_media_enabled")
    }() {
        didSet {
            UserDefaults.standard.set(isAutoPauseMacMediaEnabled, forKey: Self.keyAutoPauseMacMediaEnabled)
        }
    }
    @Published var activeIncomingCall: IncomingCallInfo? = nil

    var onSizeChangeRequested: (() -> Void)?
    
    let server = BridgeServer()
    private let launchAtLoginController: LaunchAtLoginControlling
    private let mediaPauser: MacMediaPauser
    private var lowBatteryAlertedDevices = Set<String>()
    private var dismissedCallIds = Set<String>()
    private var answeredCallIds = Set<String>()
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
    private static let keyLowBatteryAlertEnabled = "bridge_low_battery_alert_enabled"
    private static let keyAutoPauseMacMediaEnabled = "bridge_auto_pause_mac_media_enabled"
    
    init(
        startServer: Bool = true,
        launchAtLoginController: LaunchAtLoginControlling = SMAppServiceLaunchAtLoginController(),
        mediaPauser: MacMediaPauser = MacMediaPauser()
    ) {
        self.launchAtLoginController = launchAtLoginController
        self.mediaPauser = mediaPauser
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
        refreshLaunchAtLoginStatus()
        setupServerCallbacks()
        if startServer {
            server.start()
        }

        BridgeNotificationManager.shared.$activeNotifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onSizeChangeRequested?()
            }
            .store(in: &cancellables)

        BridgeNotificationManager.shared.$isCallsOnMacEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self = self else { return }
                if !enabled {
                    self.dismissCallBanner()
                }
                self.objectWillChange.send()
                self.onSizeChangeRequested?()
            }
            .store(in: &cancellables)

        BridgeFileTransferManager.shared.$transfers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.onSizeChangeRequested?()
            }
            .store(in: &cancellables)

        PhoneMirrorManager.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.onSizeChangeRequested?()
            }
            .store(in: &cancellables)

        if startServer {
            startUpdateChecking()
        }
    }
    
    private func setupServerCallbacks() {
        server.onStatusChanged = { [weak self] connected, device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnected = connected
                self.connectedDevice = device.map { formatDisplayDeviceName($0) }
                if connected {
                    if let dev = device, !dev.isEmpty {
                        let formatted = formatDisplayDeviceName(dev)
                        self.pairedDevice = formatted
                        UserDefaults.standard.set(formatted, forKey: BridgeModel.keyPairedDevice)
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
                for dev in devices where dev.hasDndPermission {
                    self.dndHintDeviceIds.remove(dev.id)
                }
                let activeIds = Set(devices.map { $0.id })
                self.dndHintDeviceIds = self.dndHintDeviceIds.intersection(activeIds)
                self.pendingRingerDeviceIds.removeAll()
                self.pendingDndDeviceIds.removeAll()
                self.pendingRingDeviceIds.removeAll()
                for id in Array(self.controlErrorHints.keys) where !activeIds.contains(id) {
                    self.controlErrorHints.removeValue(forKey: id)
                }
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

        server.onRemoteUnpair = { [weak self] deviceId, _, remainingCount in
            guard let self = self else { return }
            self.connectedDevicesList.removeAll { $0.id == deviceId }
            self.revealedDeviceIpIds.remove(deviceId)
            if remainingCount == 0 && self.connectedDevicesList.isEmpty {
                self.finalizeFullUnpairState()
            } else if let first = self.connectedDevicesList.first {
                self.pairedDevice = first.name
                self.connectedDevice = first.name
                UserDefaults.standard.set(first.name, forKey: BridgeModel.keyPairedDevice)
                if self.selectedTargetDeviceId == deviceId || self.selectedTargetDeviceId == nil {
                    self.selectedTargetDeviceId = first.id
                }
                self.onSizeChangeRequested?()
            } else {
                self.onSizeChangeRequested?()
            }
        }

        server.onDeviceBatteryUpdated = { [weak self] _, deviceName, level, isCharging in
            self?.evaluateBatteryAlert(deviceName: deviceName, level: level, isCharging: isCharging)
        }

        server.onCallEvent = { [weak self] call in
            self?.handleIncomingCallEvent(call)
        }

        server.onDeviceDisconnected = { [weak self] deviceId in
            self?.handleDeviceCallDisconnect(deviceId: deviceId)
        }
    }

    @discardableResult
    func evaluateBatteryAlert(
        deviceName: String,
        level: Int,
        isCharging: Bool,
        postNotification: Bool = true
    ) -> Bool {
        if isCharging || level >= 20 {
            lowBatteryAlertedDevices.remove(deviceName)
            return false
        }
        guard isLowBatteryAlertEnabled,
              level <= 15,
              !lowBatteryAlertedDevices.contains(deviceName) else {
            return false
        }
        lowBatteryAlertedDevices.insert(deviceName)
        if postNotification {
            postLowBatteryNotification(deviceName: deviceName, level: level)
        }
        return true
    }

    private func postLowBatteryNotification(deviceName: String, level: Int) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(deviceName) battery low (\(level)%)"
            content.body = "Plug your phone into a charger soon."
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "bridge_low_battery_\(deviceName)",
                content: content,
                trigger: nil
            )
            center.add(req, withCompletionHandler: nil)
        }
    }

    func toggleDeviceIpVisibility(_ id: UUID) {
        if revealedDeviceIpIds.contains(id) {
            revealedDeviceIpIds.remove(id)
        } else {
            revealedDeviceIpIds.insert(id)
        }
    }

    func hideAllIpAddresses() {
        isLocalIpRevealed = false
        revealedDeviceIpIds.removeAll()
    }

    // MARK: - Quick Device Controls (Sound / DND / Get Call on Mac / Ring Phone)

    var isAnyGetCallOnMacEnabled: Bool {
        return BridgeNotificationManager.shared.isCallsOnMacEnabled
    }

    func isGetCallOnMacEnabled(for device: ConnectedDeviceInfo) -> Bool {
        return BridgeNotificationManager.shared.isCallsOnMacEnabled
    }

    func toggleGetCallOnMac(for device: ConnectedDeviceInfo) {
        let next = !BridgeNotificationManager.shared.isCallsOnMacEnabled
        BridgeNotificationManager.shared.isCallsOnMacEnabled = next
        if next && UserDefaults.standard.object(forKey: Self.keyAutoPauseMacMediaEnabled) == nil {
            isAutoPauseMacMediaEnabled = true
        } else if !next {
            dismissCallBanner()
        }
        onSizeChangeRequested?()
    }

    // MARK: - Phone Mirroring Quick Control

    func phoneMirrorState(for device: ConnectedDeviceInfo) -> PhoneMirrorSessionState {
        return PhoneMirrorManager.shared.currentState(for: device.id)
    }

    func togglePhoneMirroring(for device: ConnectedDeviceInfo) {
        controlErrorHints.removeValue(forKey: device.id)
        PhoneMirrorManager.shared.toggleMirroring(for: device)
    }

    // MARK: - Incoming Call Banner & Auto-Pause Mac Media

    func handleIncomingCallEvent(_ call: IncomingCallInfo, presentPanel: Bool = true) {
        let callAllowed = BridgeNotificationManager.shared.isCallsOnMacEnabled

        if call.state == "ended" {
            dismissedCallIds.remove(call.callId)
            answeredCallIds.remove(call.callId)
            mediaPauser.clearCall(callId: call.callId)
            if activeIncomingCall?.callId == call.callId {
                activeIncomingCall = nil
            }
            if presentPanel {
                CallBannerPanelController.shared.hide(callId: call.callId)
            }
            return
        }

        guard callAllowed else {
            return
        }

        if isAutoPauseMacMediaEnabled {
            mediaPauser.pauseIfPlaying(callId: call.callId)
        }

        if dismissedCallIds.contains(call.callId) {
            if call.state == "active" && answeredCallIds.contains(call.callId) {
                dismissedCallIds.remove(call.callId)
                answeredCallIds.remove(call.callId)
            } else {
                return
            }
        }

        var resolvedCall = call
        if resolvedCall.state == "active",
           let existing = activeIncomingCall,
           existing.callId == resolvedCall.callId,
           existing.state == "active",
           let prevConnected = existing.connectedAt {
            if let newConnected = resolvedCall.connectedAt {
                if abs(newConnected.timeIntervalSince(prevConnected)) <= 2.0 {
                    resolvedCall.connectedAt = prevConnected
                }
            } else {
                resolvedCall.connectedAt = prevConnected
            }
        }

        activeIncomingCall = resolvedCall
        if presentPanel {
            CallBannerPanelController.shared.show(call: resolvedCall, model: self)
        }
    }

    func handleDeviceCallDisconnect(deviceId: UUID, presentPanel: Bool = true) {
        if let active = activeIncomingCall, active.deviceId == deviceId {
            mediaPauser.clearCall(callId: active.callId)
            dismissedCallIds.remove(active.callId)
            answeredCallIds.remove(active.callId)
            activeIncomingCall = nil
            if presentPanel {
                CallBannerPanelController.shared.hide(callId: active.callId)
            }
        }
    }

    func answerCall(_ call: IncomingCallInfo, sendToServer: Bool = true, presentPanel: Bool = true) {
        if sendToServer {
            server.sendCallAction(["action": "answer", "callId": call.callId], toDeviceId: call.deviceId)
        }
        answeredCallIds.insert(call.callId)
        dismissedCallIds.insert(call.callId)
        activeIncomingCall = nil
        if presentPanel {
            CallBannerPanelController.shared.hide(callId: call.callId)
        }
    }

    func declineCall(_ call: IncomingCallInfo, sendToServer: Bool = true, presentPanel: Bool = true) {
        if sendToServer {
            server.sendCallAction(["action": "decline", "callId": call.callId], toDeviceId: call.deviceId)
        }
        answeredCallIds.remove(call.callId)
        dismissedCallIds.insert(call.callId)
        mediaPauser.clearCall(callId: call.callId)
        activeIncomingCall = nil
        if presentPanel {
            CallBannerPanelController.shared.hide(callId: call.callId)
        }
    }

    func silenceCall(_ call: IncomingCallInfo, sendToServer: Bool = true, presentPanel: Bool = true) {
        if sendToServer {
            server.sendCallAction(["action": "silence", "callId": call.callId], toDeviceId: call.deviceId)
        }
        dismissedCallIds.insert(call.callId)
        activeIncomingCall = nil
        if presentPanel {
            CallBannerPanelController.shared.hide(callId: call.callId)
        }
    }

    func muteCall(_ call: IncomingCallInfo, sendToServer: Bool = true, presentPanel: Bool = true) {
        if call.state == "ringing" {
            silenceCall(call, sendToServer: sendToServer, presentPanel: presentPanel)
            return
        }
        if sendToServer {
            server.sendCallAction(["action": "mute", "callId": call.callId], toDeviceId: call.deviceId)
        }
        var updated = (activeIncomingCall?.callId == call.callId ? activeIncomingCall : nil) ?? call
        updated.isMuted.toggle()
        activeIncomingCall = updated
        if presentPanel {
            CallBannerPanelController.shared.show(call: updated, model: self)
        }
    }

    func dismissCallBanner(presentPanel: Bool = true) {
        if let active = activeIncomingCall {
            answeredCallIds.remove(active.callId)
            dismissedCallIds.insert(active.callId)
        }
        activeIncomingCall = nil
        if presentPanel {
            CallBannerPanelController.shared.hide()
        }
    }

    func isBatteryStale(_ device: ConnectedDeviceInfo, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard device.batteryLevel != nil else { return true }
        if let updated = device.lastBatteryUpdatedAt, (now - updated) > 300 {
            return true
        }
        return false
    }

    func cycleRingerMode(for device: ConnectedDeviceInfo, sendToServer: Bool = true) {
        let nextMode = device.ringerMode.next
        controlErrorHints.removeValue(forKey: device.id)
        if nextMode == .silent && !device.hasDndPermission {
            dndHintDeviceIds.insert(device.id)
            onSizeChangeRequested?()
            if sendToServer {
                server.sendDeviceControl([
                    "action": "set_ringer_mode",
                    "mode": nextMode.rawValue
                ], toDeviceId: device.id)
            }
            return
        }
        dndHintDeviceIds.remove(device.id)

        if sendToServer {
            pendingRingerDeviceIds.insert(device.id)
            server.sendDeviceControl([
                "action": "set_ringer_mode",
                "mode": nextMode.rawValue
            ], toDeviceId: device.id)
            scheduleControlTimeout(for: device.id, deviceName: device.name, kind: .ringer)
        } else if let idx = connectedDevicesList.firstIndex(where: { $0.id == device.id }) {
            connectedDevicesList[idx].ringerMode = nextMode
        }
    }

    func toggleDnd(for device: ConnectedDeviceInfo, sendToServer: Bool = true) {
        let targetEnabled = !device.isDndEnabled
        controlErrorHints.removeValue(forKey: device.id)
        if !device.hasDndPermission {
            dndHintDeviceIds.insert(device.id)
            onSizeChangeRequested?()
            if sendToServer {
                server.sendDeviceControl([
                    "action": "set_dnd",
                    "enabled": targetEnabled
                ], toDeviceId: device.id)
            }
            return
        }
        dndHintDeviceIds.remove(device.id)

        if sendToServer {
            pendingDndDeviceIds.insert(device.id)
            server.sendDeviceControl([
                "action": "set_dnd",
                "enabled": targetEnabled
            ], toDeviceId: device.id)
            scheduleControlTimeout(for: device.id, deviceName: device.name, kind: .dnd)
        } else if let idx = connectedDevicesList.firstIndex(where: { $0.id == device.id }) {
            connectedDevicesList[idx].isDndEnabled = targetEnabled
        }
    }

    func toggleRingPhone(for device: ConnectedDeviceInfo, sendToServer: Bool = true) {
        let targetRinging = !device.isRingingPhone
        controlErrorHints.removeValue(forKey: device.id)
        if sendToServer {
            pendingRingDeviceIds.insert(device.id)
            server.sendDeviceControl([
                "action": "ring_phone",
                "ringing": targetRinging
            ], toDeviceId: device.id)
            scheduleControlTimeout(for: device.id, deviceName: device.name, kind: .ring)
        } else if let idx = connectedDevicesList.firstIndex(where: { $0.id == device.id }) {
            connectedDevicesList[idx].isRingingPhone = targetRinging
        }
    }

    private enum PendingControlKind {
        case ringer, dnd, ring
    }

    private func scheduleControlTimeout(for deviceId: UUID, deviceName: String, kind: PendingControlKind) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self else { return }
            let stillPending: Bool
            switch kind {
            case .ringer:
                stillPending = self.pendingRingerDeviceIds.remove(deviceId) != nil
            case .dnd:
                stillPending = self.pendingDndDeviceIds.remove(deviceId) != nil
            case .ring:
                stillPending = self.pendingRingDeviceIds.remove(deviceId) != nil
            }
            if stillPending && self.connectedDevicesList.contains(where: { $0.id == deviceId }) {
                self.controlErrorHints[deviceId] = "\(deviceName) didn't confirm the change."
                self.onSizeChangeRequested?()
            }
        }
    }

    // MARK: - Media Remote Control (Now Playing on Phone)

    @Published var mediaSeekDragFraction: [UUID: Double] = [:]
    @Published var hoveredSeekDeviceId: UUID? = nil
    private var lastMediaVolumeSentAt = [UUID: TimeInterval]()

    func sendMediaPlayPause(for device: ConnectedDeviceInfo, sendToServer: Bool = true) {
        if let idx = connectedDevicesList.firstIndex(where: { $0.id == device.id }),
           var media = connectedDevicesList[idx].mediaInfo {
            let now = ProcessInfo.processInfo.systemUptime
            media.positionMs = media.estimatedPositionMs(at: now)
            media.receivedAtUptime = now
            media.isPlaying.toggle()
            connectedDevicesList[idx].mediaInfo = media
        }
        if sendToServer {
            server.sendMediaAction(["action": "play_pause"], toDeviceId: device.id)
        }
    }

    func sendMediaNext(for device: ConnectedDeviceInfo, sendToServer: Bool = true) {
        if sendToServer {
            server.sendMediaAction(["action": "next"], toDeviceId: device.id)
        }
    }

    func sendMediaPrevious(for device: ConnectedDeviceInfo, sendToServer: Bool = true) {
        if sendToServer {
            server.sendMediaAction(["action": "previous"], toDeviceId: device.id)
        }
    }

    func sendMediaSeek(for device: ConnectedDeviceInfo, positionMs: Int64, sendToServer: Bool = true) {
        let clamped = max(0, positionMs)
        if let idx = connectedDevicesList.firstIndex(where: { $0.id == device.id }),
           var media = connectedDevicesList[idx].mediaInfo {
            let maxDur = media.durationMs > 0 ? media.durationMs : clamped
            media.positionMs = min(clamped, maxDur)
            media.receivedAtUptime = ProcessInfo.processInfo.systemUptime
            connectedDevicesList[idx].mediaInfo = media
        }
        if sendToServer {
            server.sendMediaAction(["action": "seek", "positionMs": clamped], toDeviceId: device.id)
        }
    }

    func sendMediaSkip(for device: ConnectedDeviceInfo, deltaMs: Int64, sendToServer: Bool = true) {
        let currentMedia = connectedDevicesList.first(where: { $0.id == device.id })?.mediaInfo ?? device.mediaInfo
        guard let media = currentMedia else { return }
        let current = media.estimatedPositionMs()
        let rawTarget = current + deltaMs
        let target = media.durationMs > 0 ? max(0, min(media.durationMs, rawTarget)) : max(0, rawTarget)
        sendMediaSeek(for: device, positionMs: target, sendToServer: sendToServer)
    }

    func setMediaVolume(
        for device: ConnectedDeviceInfo,
        volumeIndex: Int,
        forceSend: Bool = false,
        sendToServer: Bool = true
    ) {
        let maxVol = max(1, device.mediaInfo?.maxVolume ?? 15)
        let clamped = max(0, min(maxVol, volumeIndex))
        if let idx = connectedDevicesList.firstIndex(where: { $0.id == device.id }),
           var media = connectedDevicesList[idx].mediaInfo {
            media.volumeIndex = clamped
            connectedDevicesList[idx].mediaInfo = media
        }
        guard sendToServer else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let lastSent = lastMediaVolumeSentAt[device.id] ?? 0
        if forceSend || (now - lastSent >= 0.05) {
            lastMediaVolumeSentAt[device.id] = now
            server.sendMediaAction([
                "action": "set_volume",
                "volumeIndex": clamped
            ], toDeviceId: device.id)
        }
    }

    // MARK: - Launch at Login (SMAppService)

    func refreshLaunchAtLoginStatus() {
        let state = launchAtLoginController.currentState()
        let newEnabled = state.isEnabled
        let newRequiresApproval = (state == .requiresApproval)
        let changed = (isLaunchAtLoginEnabled != newEnabled)
            || (launchAtLoginRequiresApproval != newRequiresApproval)
        isLaunchAtLoginEnabled = newEnabled
        launchAtLoginRequiresApproval = newRequiresApproval
        if newEnabled {
            launchAtLoginError = nil
        }
        if changed {
            onSizeChangeRequested?()
        }
    }

    func setLaunchAtLogin(enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try launchAtLoginController.register()
            } else {
                try launchAtLoginController.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            if enabled && Bundle.main.bundleURL.pathExtension != "app" {
                launchAtLoginError = "Run Bridge.app from Applications to enable."
            } else {
                launchAtLoginError = "Couldn't update Login Items automatically."
            }
        }
        onSizeChangeRequested?()
    }

    func openLoginItemsSettings() {
        launchAtLoginController.openLoginItemsSettings()
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
    
    private func refreshPairingCodeFromServer() {
        rawCode = server.pairingCode
        if rawCode.count == 6 {
            formattedCode = "\(rawCode.prefix(3)) \(rawCode.suffix(3))"
        } else {
            formattedCode = rawCode
        }
        updateQrCode()
    }

    private func finalizeFullUnpairState() {
        pairedDevice = nil
        connectedDevicesList.removeAll()
        selectedTargetDeviceId = nil
        deviceToUnpair = nil
        showUnpairConfirmation = false
        showPairingSection = false
        isConnected = false
        connectedDevice = nil
        hideAllIpAddresses()
        activeIncomingCall = nil
        dismissedCallIds.removeAll()
        mediaPauser.reset()
        CallBannerPanelController.shared.hide()
        UserDefaults.standard.removeObject(forKey: BridgeModel.keyPairedDevice)
        BridgeNotificationManager.shared.clearLocalNotificationsOnly()
        refreshPairingCodeFromServer()
        onSizeChangeRequested?()
    }

    func disconnect(deviceId: UUID) {
        handleDeviceCallDisconnect(deviceId: deviceId)
        server.disconnectSession(id: deviceId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            self.connectedDevicesList.removeAll { $0.id == deviceId }
            self.revealedDeviceIpIds.remove(deviceId)
            self.isConnected = !self.connectedDevicesList.isEmpty
            if let first = self.connectedDevicesList.first {
                self.connectedDevice = first.name
                self.pairedDevice = first.name
                UserDefaults.standard.set(first.name, forKey: BridgeModel.keyPairedDevice)
                if self.selectedTargetDeviceId == deviceId || self.selectedTargetDeviceId == nil {
                    self.selectedTargetDeviceId = first.id
                }
            } else {
                self.connectedDevice = nil
                self.selectedTargetDeviceId = nil
            }
            self.onSizeChangeRequested?()
        }
    }

    func unpair(deviceId: UUID? = nil) {
        if let id = deviceId {
            server.unpairDevice(id: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                self.connectedDevicesList.removeAll { $0.id == id }
                self.revealedDeviceIpIds.remove(id)
                if self.connectedDevicesList.isEmpty {
                    self.finalizeFullUnpairState()
                } else if let first = self.connectedDevicesList.first {
                    self.pairedDevice = first.name
                    self.connectedDevice = first.name
                    UserDefaults.standard.set(first.name, forKey: BridgeModel.keyPairedDevice)
                    if self.selectedTargetDeviceId == id || self.selectedTargetDeviceId == nil {
                        self.selectedTargetDeviceId = first.id
                    }
                    self.deviceToUnpair = nil
                    self.onSizeChangeRequested?()
                }
            }
        } else {
            finalizeFullUnpairState()
            server.unpairAllDevices()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.refreshPairingCodeFromServer()
                self?.onSizeChangeRequested?()
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
        panel.canChooseDirectories = true
        panel.title = "Select Files or Folders to Send to Android"
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
                               name.lowercased().contains("macos") &&
                               (name.lowercased().hasSuffix(".dmg") || name.lowercased().hasSuffix(".zip")) {
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
