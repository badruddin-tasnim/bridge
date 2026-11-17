import Foundation
import AppKit
import CoreAudio
import ApplicationServices

/// Abstraction for querying active Mac audio and pausing Mac media playback.
protocol MacMediaControlling {
    func isAudioPlaying() -> Bool
    func sendPlayPauseKey() -> Bool
    func pausePlayback() -> Bool
}

extension MacMediaControlling {
    func pausePlayback() -> Bool {
        sendPlayPauseKey()
    }
}

struct SystemMacMediaController: MacMediaControlling {
    func isAudioPlaying() -> Bool {
        var deviceId = AudioDeviceID(0)
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
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
            &propSize,
            &deviceId
        )
        guard status == noErr, deviceId != kAudioObjectUnknown else {
            return false
        }

        var isRunning: UInt32 = 0
        var runSize = UInt32(MemoryLayout<UInt32>.size)
        var runAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let runStatus = AudioObjectGetPropertyData(
            deviceId,
            &runAddress,
            0,
            nil,
            &runSize,
            &isRunning
        )
        return runStatus == noErr && isRunning != 0
    }

    func sendPlayPauseKey() -> Bool {
        // NX_KEYTYPE_PLAY = 16
        let keyPlay: Int32 = 16
        func postKey(down: Bool) -> Bool {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((keyPlay << 16) | ((down ? 0xa : 0xb) << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ),
            let cgEvent = event.cgEvent else {
                return false
            }
            cgEvent.post(tap: .cghidEventTap)
            return true
        }
        return postKey(down: true) && postKey(down: false)
    }

    func pausePlayback() -> Bool {
        if MacMediaControlCLI.shared.isAvailable, MacMediaControlCLI.shared.pause() {
            return true
        }
        return sendPlayPauseKey()
    }
}

/// Pauses Mac audio when a phone call rings or becomes active, guarding against
/// double-toggling Play/Pause across ringing -> active transitions.
final class MacMediaPauser {
    private let controller: MacMediaControlling
    private var handledCallIds = Set<String>()

    init(controller: MacMediaControlling = SystemMacMediaController()) {
        self.controller = controller
    }

    @discardableResult
    func pauseIfPlaying(callId: String) -> Bool {
        guard !handledCallIds.contains(callId) else {
            return false
        }
        guard controller.isAudioPlaying() else {
            return false
        }
        handledCallIds.insert(callId)
        return controller.pausePlayback()
    }

    func clearCall(callId: String) {
        handledCallIds.remove(callId)
    }

    func reset() {
        handledCallIds.removeAll()
    }
}
