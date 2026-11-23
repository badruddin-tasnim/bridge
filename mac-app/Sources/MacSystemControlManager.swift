import Foundation
import CoreAudio
import AudioToolbox
import IOKit.ps

/// Snapshot of Mac battery, mute state (`Sound` <-> `Silent`), and output volume.
struct MacSystemStatusSnapshot: Equatable {
    var batteryPercent: Int?
    var isCharging: Bool
    var isMuted: Bool
    var volumePercent: Int
    var canToggleMute: Bool
    var canControlVolume: Bool

    func toJsonObject() -> [String: Any] {
        var obj: [String: Any] = [
            "type": "mac_status",
            "isCharging": isCharging,
            "isMuted": isMuted,
            "volumePercent": volumePercent,
            "canToggleMute": canToggleMute,
            "canControlVolume": canControlVolume
        ]
        if let batteryPercent {
            obj["batteryPercent"] = batteryPercent
        }
        return obj
    }

    func toJsonString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: toJsonObject(), options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

protocol MacSystemControlProviding {
    func readSnapshot() -> MacSystemStatusSnapshot
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool
    @discardableResult
    func setVolumePercent(_ percent: Int) -> Bool
}

/// Reads MacBook battery via IOKit and reads/controls Mac output mute & volume via CoreAudio.
final class SystemMacControlProvider: MacSystemControlProviding {
    static func readInternalBattery() -> (percent: Int?, isCharging: Bool) {
        guard let infoRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(infoRef)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false)
        }

        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(infoRef, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let type = desc[kIOPSTypeKey as String] as? String
            if let type, type != kIOPSInternalBatteryType as String {
                continue
            }
            let isPresent = (desc[kIOPSIsPresentKey as String] as? Bool) ?? true
            guard isPresent,
                  let cur = desc[kIOPSCurrentCapacityKey as String] as? Int,
                  let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int,
                  maxCap > 0 else {
                continue
            }
            let pct = max(0, min(100, Int((Double(cur) / Double(maxCap) * 100.0).rounded())))
            let isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
            return (pct, isCharging)
        }
        return (nil, false)
    }

    static func defaultOutputDeviceId() -> AudioObjectID {
        var deviceId = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceId
        )
        return status == noErr ? deviceId : AudioObjectID(kAudioObjectUnknown)
    }

    private func resolveMuteAddress(deviceId: AudioObjectID) -> AudioObjectPropertyAddress? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceId, &addr) {
                return addr
            }
        }
        return nil
    }

    private func resolveVolumeAddress(deviceId: AudioObjectID) -> AudioObjectPropertyAddress? {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceId, &virtualAddr) {
            return virtualAddr
        }
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var scalarAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceId, &scalarAddr) {
                return scalarAddr
            }
        }
        return nil
    }

    func readSnapshot() -> MacSystemStatusSnapshot {
        let battery = Self.readInternalBattery()
        let deviceId = Self.defaultOutputDeviceId()
        guard deviceId != kAudioObjectUnknown else {
            return MacSystemStatusSnapshot(
                batteryPercent: battery.percent,
                isCharging: battery.isCharging,
                isMuted: false,
                volumePercent: 0,
                canToggleMute: false,
                canControlVolume: false
            )
        }

        var isMuted = false
        var canToggleMute = false
        if var muteAddr = resolveMuteAddress(deviceId: deviceId) {
            var muteVal: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceId, &muteAddr, 0, nil, &size, &muteVal) == noErr {
                isMuted = (muteVal != 0)
            }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceId, &muteAddr, &settable) == noErr {
                canToggleMute = settable.boolValue
            }
        }

        var volumePercent = 0
        var canControlVolume = false
        if var volAddr = resolveVolumeAddress(deviceId: deviceId) {
            var volVal: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceId, &volAddr, 0, nil, &size, &volVal) == noErr {
                volumePercent = max(0, min(100, Int((volVal * 100.0).rounded())))
            }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceId, &volAddr, &settable) == noErr {
                canControlVolume = settable.boolValue
            }
        }

        return MacSystemStatusSnapshot(
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            isMuted: isMuted,
            volumePercent: volumePercent,
            canToggleMute: canToggleMute,
            canControlVolume: canControlVolume
        )
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        let deviceId = Self.defaultOutputDeviceId()
        guard deviceId != kAudioObjectUnknown,
              var muteAddr = resolveMuteAddress(deviceId: deviceId) else {
            return false
        }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceId, &muteAddr, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var val: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceId, &muteAddr, 0, nil, size, &val) == noErr
    }

    @discardableResult
    func setVolumePercent(_ percent: Int) -> Bool {
        let clamped = max(0, min(100, percent))
        let deviceId = Self.defaultOutputDeviceId()
        guard deviceId != kAudioObjectUnknown else { return false }

        // Unmute automatically if user slides volume above 0 while muted (standard macOS behavior).
        if clamped > 0 {
            let current = readSnapshot()
            if current.isMuted && current.canToggleMute {
                _ = setMuted(false)
            }
        }

        var scalar = Float32(Double(clamped) / 100.0)
        let size = UInt32(MemoryLayout<Float32>.size)
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceId, &virtualAddr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceId, &virtualAddr, &settable) == noErr, settable.boolValue {
                return AudioObjectSetPropertyData(deviceId, &virtualAddr, 0, nil, size, &scalar) == noErr
            }
        }

        var anySet = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceId, &addr) {
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(deviceId, &addr, &settable) == noErr, settable.boolValue {
                    if AudioObjectSetPropertyData(deviceId, &addr, 0, nil, size, &scalar) == noErr {
                        anySet = true
                    }
                }
            }
        }
        return anySet
    }
}

final class MacSystemControlManager {
    static let shared = MacSystemControlManager()

    private let provider: MacSystemControlProviding
    private let stateQueue = DispatchQueue(label: "com.link.bridge.macControl", qos: .utility)

    var onStatusChanged: ((String) -> Void)?

    private var isRunning = false
    private var lastSnapshot: MacSystemStatusSnapshot?
    private var powerRunLoopSource: CFRunLoopSource?
    private var batteryFallbackTimer: DispatchSourceTimer?

    private var systemDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var observedDeviceId = AudioObjectID(kAudioObjectUnknown)
    private var deviceMuteListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceVolumeListenerBlock: AudioObjectPropertyListenerBlock?

    init(provider: MacSystemControlProviding = SystemMacControlProvider()) {
        self.provider = provider
    }

    func start() {
        stateQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.attachCoreAudioListeners()
            self.attachPowerSourceObserver()
            self.refreshAndBroadcastIfNeeded(force: true)
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            self.detachCoreAudioListeners()
            self.detachPowerSourceObserver()
        }
    }

    func currentStatusJson() -> String? {
        return stateQueue.sync {
            let snap = provider.readSnapshot()
            lastSnapshot = snap
            return snap.toJsonString()
        }
    }

    func handleControlCommand(jsonObject: [String: Any]) {
        guard let action = jsonObject["action"] as? String else { return }
        stateQueue.async { [weak self] in
            guard let self else { return }
            let current = self.provider.readSnapshot()
            switch action {
            case "toggle_mute":
                _ = self.provider.setMuted(!current.isMuted)
            case "set_mute":
                if let muted = jsonObject["muted"] as? Bool {
                    _ = self.provider.setMuted(muted)
                }
            case "set_volume":
                if let vol = (jsonObject["volumePercent"] as? NSNumber)?.intValue {
                    _ = self.provider.setVolumePercent(vol)
                }
            default:
                return
            }
            self.refreshAndBroadcastIfNeeded(force: true)
        }
    }

    private func refreshAndBroadcastIfNeeded(force: Bool = false) {
        let snap = provider.readSnapshot()
        if !force, let prev = lastSnapshot, prev == snap {
            return
        }
        lastSnapshot = snap
        guard let json = snap.toJsonString() else { return }
        onStatusChanged?(json)
    }

    private func attachCoreAudioListeners() {
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sysBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRunning else { return }
            self.detachDeviceListeners()
            self.attachDeviceListeners()
            self.refreshAndBroadcastIfNeeded(force: true)
        }
        systemDeviceListenerBlock = sysBlock
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &sysAddr,
            stateQueue,
            sysBlock
        )
        attachDeviceListeners()
    }

    private func attachDeviceListeners() {
        let devId = SystemMacControlProvider.defaultOutputDeviceId()
        guard devId != kAudioObjectUnknown else {
            observedDeviceId = AudioObjectID(kAudioObjectUnknown)
            return
        }
        observedDeviceId = devId

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devId, &muteAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isRunning else { return }
                self.refreshAndBroadcastIfNeeded()
            }
            deviceMuteListenerBlock = block
            AudioObjectAddPropertyListenerBlock(devId, &muteAddr, stateQueue, block)
        }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devId, &volAddr) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.isRunning else { return }
                self.refreshAndBroadcastIfNeeded()
            }
            deviceVolumeListenerBlock = block
            AudioObjectAddPropertyListenerBlock(devId, &volAddr, stateQueue, block)
        }
    }

    private func detachDeviceListeners() {
        guard observedDeviceId != kAudioObjectUnknown else { return }
        let devId = observedDeviceId
        if let block = deviceMuteListenerBlock {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(devId, &muteAddr, stateQueue, block)
            deviceMuteListenerBlock = nil
        }
        if let block = deviceVolumeListenerBlock {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(devId, &volAddr, stateQueue, block)
            deviceVolumeListenerBlock = nil
        }
        observedDeviceId = AudioObjectID(kAudioObjectUnknown)
    }

    private func detachCoreAudioListeners() {
        detachDeviceListeners()
        if let sysBlock = systemDeviceListenerBlock {
            var sysAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &sysAddr,
                stateQueue,
                sysBlock
            )
            systemDeviceListenerBlock = nil
        }
    }

    private func attachPowerSourceObserver() {
        let contextPtr = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let mgr = Unmanaged<MacSystemControlManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.stateQueue.async {
                guard mgr.isRunning else { return }
                mgr.refreshAndBroadcastIfNeeded()
            }
        }, contextPtr)?.takeRetainedValue() {
            powerRunLoopSource = source
            DispatchQueue.main.async {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunning else { return }
            self.refreshAndBroadcastIfNeeded()
        }
        batteryFallbackTimer = timer
        timer.resume()
    }

    private func detachPowerSourceObserver() {
        batteryFallbackTimer?.cancel()
        batteryFallbackTimer = nil
        if let source = powerRunLoopSource {
            powerRunLoopSource = nil
            DispatchQueue.main.async {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
    }
}
